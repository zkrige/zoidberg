import sys, re

text = sys.argv[1]

# Escape HTML special chars first
text = text.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')

# Fenced code blocks (``` lang\n ... ```)
def replace_code_block(m):
    inner = m.group(2).strip()
    return f'<pre>{inner}</pre>'
text = re.sub(r'```[^\n]*\n([\s\S]*?)```', lambda m: f'<pre>{m.group(1).rstrip()}</pre>', text)

# Inline code
text = re.sub(r'`([^`\n]+)`', r'<code>\1</code>', text)

# Protect already-converted <pre> and <code> blocks from inline formatting regexes.
# Without this, italic/bold patterns can match across tag boundaries producing malformed HTML.
placeholders = {}
ph_idx = [0]
def protect(m):
    key = f'\x00PH{ph_idx[0]}\x00'
    placeholders[key] = m.group(0)
    ph_idx[0] += 1
    return key
text = re.sub(r'<pre>[\s\S]*?</pre>', protect, text)
text = re.sub(r'<code>[^<]*</code>', protect, text)

# Headings -> bold line
text = re.sub(r'^#{1,6}\s+(.+)$', r'<b>\1</b>', text, flags=re.MULTILINE)

# Bold **text** or __text__
text = re.sub(r'\*\*(.+?)\*\*', r'<b>\1</b>', text)
text = re.sub(r'__(.+?)__', r'<b>\1</b>', text)

# Italic *text* or _text_ (single, not double)
text = re.sub(r'\*([^*\n]+)\*', r'<i>\1</i>', text)
text = re.sub(r'(?<!\w)_([^_\n]+)_(?!\w)', r'<i>\1</i>', text)

# Blockquotes: consecutive '> ' lines -> <blockquote> (expandable when long).
# Runs while code is still placeheld so a '>' line inside a fenced block is untouched.
bq_marker = re.compile(r'^\s*&gt;\s?')
def group_blockquotes(src):
    lines = src.split('\n')
    out = []
    i = 0
    while i < len(lines):
        if bq_marker.match(lines[i]):
            block = []
            while i < len(lines) and bq_marker.match(lines[i]):
                block.append(bq_marker.sub('', lines[i]))
                i += 1
            tag = '<blockquote expandable>' if len(block) > 10 else '<blockquote>'
            out.append(tag + '\n'.join(block) + '</blockquote>')
        else:
            out.append(lines[i])
            i += 1
    return '\n'.join(out)
text = group_blockquotes(text)

# Restore protected blocks
for key, val in placeholders.items():
    text = text.replace(key, val)

# Strikethrough ~~text~~
text = re.sub(r'~~(.+?)~~', r'<s>\1</s>', text)

# Links [text](url)
text = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'<a href="\2">\1</a>', text)

# Tables -> monospaced pre block
def render_table(m):
    lines = [l.strip() for l in m.group(0).strip().split('\n')]
    # Filter separator rows (---|--- style)
    rows = [l for l in lines if not re.match(r'^[\|\s\-:]+$', l)]
    parsed = []
    for row in rows:
        cells = [c.strip() for c in row.strip('|').split('|')]
        parsed.append(cells)
    if not parsed:
        return m.group(0)
    cols = max(len(r) for r in parsed)
    # Pad all rows to same col count
    for r in parsed:
        while len(r) < cols:
            r.append('')
    widths = [max(len(r[i]) for r in parsed) for i in range(cols)]
    out_lines = []
    for idx, row in enumerate(parsed):
        out_lines.append('  '.join(cell.ljust(widths[i]) for i, cell in enumerate(row)).rstrip())
        if idx == 0:
            out_lines.append('  '.join('─' * widths[i] for i in range(cols)))
    return '<pre>' + '\n'.join(out_lines) + '</pre>'

text = re.sub(r'(?m)^(\|.+(\n|$))+', render_table, text)

# Horizontal rule
text = re.sub(r'^---+$', '─────────────', text, flags=re.MULTILINE)

print(text, end='')
