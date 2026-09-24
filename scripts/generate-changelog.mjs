#!/usr/bin/env node
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const root = new URL('../', import.meta.url);
const changelogPath = new URL('CHANGELOG.md', root);
const outputPath = new URL('site/public/changelog.json', root);

/**
 * Parse CHANGELOG.md into structured JSON.
 * Format: ## version — Released date
 * Sections under a version are text blocks until next ## or ###
 */
async function generateChangelog() {
  const markdown = await readFile(changelogPath, 'utf8');
  const lines = markdown.split('\n');
  
  const releases = [];
  let currentRelease = null;
  let currentContent = [];
  
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    
    // Match version headers: ## 0.1.13 — Released 2026-09-23
    const versionMatch = line.match(/^##\s+([\d.]+)\s+—\s+Released\s+([\d-]+)/);
    if (versionMatch) {
      // Save previous release if exists
      if (currentRelease) {
        currentRelease.notes = currentContent.join('\n').trim();
        releases.push(currentRelease);
      }
      
      // Start new release
      currentRelease = {
        version: versionMatch[1],
        date: versionMatch[2],
        notes: ''
      };
      currentContent = [];
      continue;
    }
    
    // Match subsection headers like ### 0.1.11 development work included in 0.1.12
    const subsectionMatch = line.match(/^###\s+(.+)$/);
    if (subsectionMatch && currentRelease) {
      currentContent.push(line);
      continue;
    }
    
    // Match initial release header: ## 0.1.0 — Initial public release
    const initialMatch = line.match(/^##\s+([\d.]+)\s+—\s+(.+)$/);
    if (initialMatch && !versionMatch) {
      if (currentRelease) {
        currentRelease.notes = currentContent.join('\n').trim();
        releases.push(currentRelease);
      }
      // Candidate sections belong in the source changelog, not in the public
      // release list. Only the historical initial-release heading is undated.
      if (initialMatch[2] !== 'Initial public release') {
        currentRelease = null;
        currentContent = [];
        continue;
      }
      
      currentRelease = {
        version: initialMatch[1],
        date: initialMatch[2],
        notes: ''
      };
      currentContent = [];
      continue;
    }
    
    // Collect content for current release
    if (currentRelease && line !== '# Changelog') {
      currentContent.push(line);
    }
  }
  
  // Save final release
  if (currentRelease) {
    currentRelease.notes = currentContent.join('\n').trim();
    releases.push(currentRelease);
  }
  
  const changelog = {
    generated: new Date().toISOString(),
    releases
  };
  
  await writeFile(outputPath, JSON.stringify(changelog, null, 2) + '\n');
  console.log(`Generated changelog.json with ${releases.length} releases`);
  
  return changelog;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  await generateChangelog();
}

export { generateChangelog };
