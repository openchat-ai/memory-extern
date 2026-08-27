#!/usr/bin/env python3
"""
md2wechat.py — Markdown → 公众号 HTML 转换器
用法: python3 md2wechat.py notes/series/01-situ-glu.md
输出: notes/series/html/01-situ-glu.html
"""
import sys, os, re

# 公众号友好的内联样式
STYLES = {
    'body': 'max-width:677px;margin:0 auto;padding:20px 16px;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;color:#333;line-height:1.8;font-size:16px;',
    'h1': 'font-size:22px;font-weight:bold;color:#1a1a1a;margin:30px 0 15px;padding-bottom:10px;border-bottom:2px solid #e74c3c;',
    'h2': 'font-size:18px;font-weight:bold;color:#2c3e50;margin:25px 0 12px;padding-left:10px;border-left:4px solid #3498db;',
    'h3': 'font-size:16px;font-weight:bold;color:#34495e;margin:20px 0 10px;',
    'p': 'margin:10px 0;text-align:justify;',
    'blockquote': 'margin:15px 0;padding:12px 16px;background:#f8f9fa;border-left:4px solid #e74c3c;color:#555;font-size:15px;',
    'code_block': 'display:block;margin:12px 0;padding:14px 16px;background:#1e1e1e;color:#d4d4d4;font-family:"Fira Code","SF Mono",Menlo,monospace;font-size:13px;line-height:1.6;border-radius:8px;overflow-x:auto;white-space:pre-wrap;word-break:break-all;',
    'code_inline': 'padding:2px 6px;background:#f1f3f5;color:#e74c3c;font-family:"Fira Code","SF Mono",Menlo,monospace;font-size:14px;border-radius:3px;',
    'strong': 'color:#e74c3c;font-weight:bold;',
    'em': 'color:#7f8c8d;font-style:italic;',
    'ul': 'margin:10px 0;padding-left:20px;',
    'li': 'margin:5px 0;',
    'table': 'width:100%;border-collapse:collapse;margin:15px 0;font-size:14px;',
    'th': 'padding:10px 12px;background:#3498db;color:white;text-align:left;font-weight:bold;',
    'td': 'padding:8px 12px;border-bottom:1px solid #ecf0f1;',
    'hr': 'border:none;border-top:1px dashed #bdc3c7;margin:25px 0;',
    'img': 'max-width:100%;border-radius:8px;margin:15px 0;',
    'link': 'color:#3498db;text-decoration:none;border-bottom:1px solid #3498db;',
}

def md_to_html(md_text):
    """简单 Markdown → HTML 转换"""
    lines = md_text.split('\n')
    html_parts = []
    in_code_block = False
    code_lines = []
    in_table = False
    table_rows = []

    i = 0
    while i < len(lines):
        line = lines[i]

        # 代码块
        if line.strip().startswith('```'):
            if in_code_block:
                code_content = '\n'.join(code_lines)
                html_parts.append(f'<pre style="{STYLES["code_block"]}">{code_content}</pre>')
                code_lines = []
                in_code_block = False
            else:
                in_code_block = True
            i += 1
            continue

        if in_code_block:
            code_lines.append(line.replace('<', '&lt;').replace('>', '&gt;'))
            i += 1
            continue

        # 表格
        if '|' in line and line.strip().startswith('|'):
            if not in_table:
                in_table = True
                table_rows = []
            # 跳过分隔行
            if re.match(r'^\|[\s\-|]+\|$', line.strip()):
                i += 1
                continue
            cells = [c.strip() for c in line.strip().split('|')[1:-1]]
            table_rows.append(cells)
            # 检查下一行是否还是表格
            if i + 1 < len(lines) and '|' in lines[i+1] and lines[i+1].strip().startswith('|'):
                i += 1
                continue
            else:
                # 输出表格
                html_parts.append(render_table(table_rows))
                in_table = False
                table_rows = []
                i += 1
                continue

        # 标题
        if line.startswith('# '):
            html_parts.append(f'<h1 style="{STYLES["h1"]}">{inline_format(line[2:])}</h1>')
        elif line.startswith('## '):
            html_parts.append(f'<h2 style="{STYLES["h2"]}">{inline_format(line[3:])}</h2>')
        elif line.startswith('### '):
            html_parts.append(f'<h3 style="{STYLES["h3"]}">{inline_format(line[4:])}</h3>')
        # 引用
        elif line.startswith('> '):
            html_parts.append(f'<blockquote style="{STYLES["blockquote"]}">{inline_format(line[2:])}</blockquote>')
        # 分割线
        elif line.strip() in ('---', '***', '___'):
            html_parts.append(f'<hr style="{STYLES["hr"]}"/>')
        # 空行
        elif line.strip() == '':
            pass
        # 普通段落
        else:
            html_parts.append(f'<p style="{STYLES["p"]}">{inline_format(line)}</p>')

        i += 1

    return '\n'.join(html_parts)

def inline_format(text):
    """处理行内格式：加粗、斜体、行内代码、链接"""
    # 行内代码（先处理，避免被其他规则干扰）
    text = re.sub(r'`([^`]+)`', rf'<code style="{STYLES["code_inline"]}">\1</code>', text)
    # 加粗
    text = re.sub(r'\*\*(.+?)\*\*', rf'<strong style="{STYLES["strong"]}">\1</strong>', text)
    # 斜体
    text = re.sub(r'\*(.+?)\*', rf'<em style="{STYLES["em"]}">\1</em>', text)
    # 链接
    text = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', rf'<a style="{STYLES["link"]}" href="\2">\1</a>', text)
    return text

def render_table(rows):
    """渲染表格"""
    if not rows:
        return ''
    html = f'<table style="{STYLES["table"]}">'
    # 第一行是表头
    html += '<thead><tr>'
    for cell in rows[0]:
        html += f'<th style="{STYLES["th"]}">{inline_format(cell)}</th>'
    html += '</tr></thead>'
    # 剩余行
    if len(rows) > 1:
        html += '<tbody>'
        for row in rows[1:]:
            html += '<tr>'
            for cell in row:
                html += f'<td style="{STYLES["td"]}">{inline_format(cell)}</td>'
            html += '</tr>'
        html += '</tbody>'
    html += '</table>'
    return html

def wrap_html(body, title):
    """包装成完整 HTML"""
    return f'''<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>{title}</title>
</head>
<body>
<div style="{STYLES['body']}">
{body}
</div>
</body>
</html>'''

def convert_file(md_path, out_dir):
    """转换单个文件"""
    with open(md_path, 'r', encoding='utf-8') as f:
        md_text = f.read()

    # 提取标题（第一行 # 开头）
    title_match = re.search(r'^#\s+(.+)$', md_text, re.MULTILINE)
    title = title_match.group(1) if title_match else os.path.basename(md_path)

    body = md_to_html(md_text)
    html = wrap_html(body, title)

    # 输出文件名
    basename = os.path.splitext(os.path.basename(md_path))[0]
    out_path = os.path.join(out_dir, f'{basename}.html')
    os.makedirs(out_dir, exist_ok=True)

    with open(out_path, 'w', encoding='utf-8') as f:
        f.write(html)

    print(f'✅ {md_path} → {out_path}')
    return out_path

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('用法: python3 md2wechat.py <md文件或目录> [输出目录]')
        sys.exit(1)

    md_input = sys.argv[1]
    out_dir = sys.argv[2] if len(sys.argv) > 2 else 'html'

    if os.path.isdir(md_input):
        for f in sorted(os.listdir(md_input)):
            if f.endswith('.md'):
                convert_file(os.path.join(md_input, f), out_dir)
    else:
        convert_file(md_input, out_dir)
