#!/usr/bin/env node

import { appendFileSync, readFileSync } from 'node:fs'

export interface HomebrewRelease {
  version: string
  sha256: string
  downloadUrl: string
}

const caskLocation = {
  contentsUrl: 'https://api.github.com/repos/codex-ecosystem/homebrew-tap/contents/Casks/codex-agent-bar.rb',
  branch: 'main',
}
const templatePath = new URL('./template.rb.in', import.meta.url)

type Request = typeof fetch
interface GitHubFileLocation { contentsUrl: string, branch: string }
interface GitHubFile { content: string, sha: string }
interface GitHubFileUpdate { content: string, message: string, sha?: string }

// Reusable utilities.
function renderTemplate(template: string, values: Record<string, string>): string {
  return template.replace(/@([A-Z0-9_]+)@/g, (placeholder, key: string) => values[key] ?? placeholder)
}

function compareVersions(left: string, right: string): number {
  const a = left.split('.').map(BigInt)
  const b = right.split('.').map(BigInt)
  for (let index = 0; index < 3; index++) {
    if (a[index] !== b[index])
      return a[index] > b[index] ? 1 : -1
  }
  return 0
}

function githubHeaders(token: string): Record<string, string> {
  if (!token)
    throw new Error('A GitHub installation token is required')
  return {
    'Authorization': `Bearer ${token}`,
    'Accept': 'application/vnd.github+json',
    'Content-Type': 'application/json',
    'X-GitHub-Api-Version': '2022-11-28',
  }
}

async function readGitHubFile(location: GitHubFileLocation, token: string, request: Request): Promise<GitHubFile | undefined> {
  const response = await request(`${location.contentsUrl}?ref=${encodeURIComponent(location.branch)}`, { headers: githubHeaders(token) })
  if (response.status === 404 || response.status === 409)
    return undefined
  if (!response.ok)
    throw new Error(`Reading the GitHub file failed: HTTP ${response.status}`)
  const file = await response.json()
  if (file.type !== 'file' || file.encoding !== 'base64' || !file.sha || typeof file.content !== 'string') {
    throw new Error('The GitHub API did not return a file')
  }
  return { content: Buffer.from(file.content, 'base64').toString('utf8'), sha: file.sha }
}

async function writeGitHubFile(location: GitHubFileLocation, file: GitHubFileUpdate, token: string, request: Request): Promise<void> {
  const response = await request(location.contentsUrl, {
    method: 'PUT',
    headers: githubHeaders(token),
    body: JSON.stringify({
      message: file.message,
      content: Buffer.from(file.content).toString('base64'),
      branch: location.branch,
      ...(file.sha ? { sha: file.sha } : {}),
    }),
  })
  if (!response.ok)
    throw new Error(`Writing the GitHub file failed: HTTP ${response.status}`)
}

// Homebrew release logic.
function validateRelease(release: HomebrewRelease): void {
  if (!/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(release.version)) {
    throw new Error('Homebrew requires a stable MAJOR.MINOR.PATCH release version')
  }
  if (!/^[a-f0-9]{64}$/.test(release.sha256)) {
    throw new Error('The release must have a SHA-256 checksum')
  }
  const expectedUrl = `https://github.com/codex-ecosystem/codex-agent-bar/releases/download/v${release.version}/AgentBar-${release.version}.dmg`
  if (release.downloadUrl !== expectedUrl) {
    throw new Error('The DMG URL does not match the released version')
  }
}

function parseCaskMetadata(content: string): { version: string, sha256: string, url: string } {
  const version = content.match(/^ {2}version "((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))"$/m)?.[1]
  const sha256 = content.match(/^ {2}sha256 "([a-f0-9]{64})"$/m)?.[1]
  const url = content.match(/^ {2}url "([^"]+)"$/m)?.[1]
  if (!version || !sha256 || !url)
    throw new Error('The existing cask has invalid release metadata')
  return { version, sha256, url: url.replaceAll('#{version}', version) }
}

export function renderCask(release: HomebrewRelease): string {
  validateRelease(release)
  return renderTemplate(readFileSync(templatePath, 'utf8'), {
    VERSION: release.version,
    SHA256: release.sha256,
    DOWNLOAD_URL: release.downloadUrl,
  })
}

async function writeCask(version: string, content: string, token: string, sha: string | undefined, request: Request): Promise<void> {
  await writeGitHubFile(caskLocation, {
    message: `chore: publish codex-agent-bar ${version}`,
    content,
    sha,
  }, token, request)
}

export async function prepareHomebrew(release: HomebrewRelease, token: string, request: Request = fetch): Promise<'created' | 'update' | 'unchanged' | 'newer-version'> {
  const content = renderCask(release)
  const file = await readGitHubFile(caskLocation, token, request)
  if (!file) {
    await writeCask(release.version, content, token, undefined, request)
    return 'created'
  }
  const previous = parseCaskMetadata(file.content)
  const comparison = compareVersions(release.version, previous.version)
  if (comparison < 0)
    return 'newer-version'
  if (comparison > 0)
    return 'update'
  if (previous.sha256 !== release.sha256) {
    throw new Error('Refusing to replace an existing release with a different DMG checksum')
  }
  return 'unchanged'
}

export async function finalizeHomebrew(release: HomebrewRelease, token: string, request: Request = fetch): Promise<void> {
  const expected = renderCask(release)
  const file = await readGitHubFile(caskLocation, token, request)
  if (!file)
    throw new Error('The published Homebrew cask is missing')
  const current = parseCaskMetadata(file.content)
  if (current.version !== release.version || current.sha256 !== release.sha256 || current.url !== release.downloadUrl) {
    throw new Error('The published Homebrew cask does not match the verified release')
  }
  // Propagate bundle, platform, and uninstall changes from the upstream template too.
  if (file.content !== expected)
    await writeCask(release.version, expected, token, file.sha, request)
  const verified = await readGitHubFile(caskLocation, token, request)
  if (verified?.content !== expected)
    throw new Error('Homebrew publication verification failed')
}

if (import.meta.main) {
  try {
    const release = {
      version: process.env.RELEASE_VERSION ?? '',
      sha256: process.env.RELEASE_SHA256 ?? '',
      downloadUrl: process.env.RELEASE_DOWNLOAD_URL ?? '',
    }
    const token = process.env.HOMEBREW_TAP_TOKEN ?? ''
    if (process.argv[2] === 'finalize') {
      await finalizeHomebrew(release, token)
      console.log(`Verified Homebrew publication for ${release.version}`)
    }
    else if (process.argv[2] === 'prepare') {
      const result = await prepareHomebrew(release, token)
      if (process.env.GITHUB_OUTPUT)
        appendFileSync(process.env.GITHUB_OUTPUT, `result=${result}\n`)
      console.log(`Homebrew release ${release.version}: ${result}`)
    }
    else {
      throw new Error('Usage: node .github/actions/publish-homebrew/release.mts prepare|finalize')
    }
  }
  catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
