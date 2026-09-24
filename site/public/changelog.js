async function loadChangelog() {
  try {
    const response = await fetch('/changelog.json');
    const data = await response.json();
    const container = document.getElementById('changelog-content');

    if (!data.releases || data.releases.length === 0) {
      container.innerHTML = '<p>No releases found.</p>';
      return;
    }

    let html = '';
    for (const release of data.releases) {
      html += `<article class="release-entry">`;
      html += `<h2 id="v${release.version}">Version ${release.version}</h2>`;
      html += `<p class="release-date">Released ${release.date}</p>`;
      html += `<div class="release-notes">${formatNotes(release.notes)}</div>`;
      html += `</article>`;
    }

    container.innerHTML = html;
  } catch (error) {
    console.error('Failed to load changelog:', error);
    document.getElementById('changelog-content').innerHTML =
      '<p>Failed to load changelog. Please see the <a href="https://github.com/rogu3bear/token-bar/blob/main/CHANGELOG.md">CHANGELOG.md on GitHub</a>.</p>';
  }
}

function formatNotes(notes) {
  // Convert markdown-style lists and sections to HTML
  const lines = notes.split('\n');
  let html = '';
  let inList = false;

  for (let line of lines) {
    if (line.trim() === '') {
      if (inList) {
        html += '</ul>';
        inList = false;
      }
      continue;
    }

    // Handle subsection headers (###)
    if (line.startsWith('###')) {
      if (inList) {
        html += '</ul>';
        inList = false;
      }
      html += `<h3>${line.replace(/^###\s*/, '')}</h3>`;
      continue;
    }

    // Handle list items
    if (line.startsWith('- ')) {
      if (!inList) {
        html += '<ul>';
        inList = true;
      }
      html += `<li>${escapeHtml(line.substring(2))}</li>`;
    } else {
      if (inList) {
        html += '</ul>';
        inList = false;
      }
      html += `<p>${escapeHtml(line)}</p>`;
    }
  }

  if (inList) {
    html += '</ul>';
  }

  return html;
}

function escapeHtml(text) {
  const div = document.createElement('div');
  div.textContent = text;
  return div.innerHTML;
}

document.addEventListener('DOMContentLoaded', loadChangelog);
