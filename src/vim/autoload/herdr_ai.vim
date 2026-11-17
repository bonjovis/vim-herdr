" ============================================================
"  herdr_ai.vim —— Vim 选中方法发送至 AI Agent CLI 并在新 Tab 展示与追问
" ============================================================

let s:script_path = expand('~/.vim/scripts/ask_ai.py')
let s:tab_seq = 0

function! s:project_root(path) abort
  let l:dir = isdirectory(a:path) ? a:path : fnamemodify(a:path, ':h')
  if empty(l:dir)
    let l:dir = getcwd()
  endif
  for l:marker in ['go.mod', 'pom.xml', 'build.gradle', 'build.gradle.kts', 'package.json', 'composer.json']
    let l:found = findfile(l:marker, l:dir . ';')
    if !empty(l:found)
      return fnamemodify(l:found, ':h')
    endif
  endfor
  for l:marker in ['.git', '.hg', '.svn']
    let l:found = finddir(l:marker, l:dir . ';')
    if !empty(l:found)
      return fnamemodify(l:found, ':h')
    endif
    let l:found = findfile(l:marker, l:dir . ';')
    if !empty(l:found)
      return fnamemodify(l:found, ':h')
    endif
  endfor
  return l:dir
endfunction

function! s:resolve_current_cwd() abort
  if exists('b:herdr_ai_state') && type(b:herdr_ai_state) == type({}) && !empty(get(b:herdr_ai_state, 'cwd', ''))
    return b:herdr_ai_state.cwd
  endif
  let l:bufname = bufname('%')
  let l:full_path = expand('%:p')
  if &buftype !=# '' || empty(l:full_path) || l:bufname =~# '^\a\w*://' || l:full_path =~# '^\a\w*://'
    return s:project_root(getcwd())
  endif
  return s:project_root(l:full_path)
endfunction

function! s:extract_context(mode) abort
  let l:bufname = bufname('%')
  let l:full_path = expand('%:p')
  let l:is_virtual = (&buftype !=# '' || empty(l:full_path) || l:bufname =~# '^\a\w*://' || l:full_path =~# '^\a\w*://')
  let l:cwd = s:resolve_current_cwd()
  let l:rel_file = l:is_virtual ? '[No Name]' : fnamemodify(l:full_path, ':~:.')
  if !l:is_virtual && stridx(l:full_path, l:cwd . '/') == 0
    let l:rel_file = strpart(l:full_path, len(l:cwd) + 1)
  endif

  let l:symbol = expand('<cword>')
  let l:curline = line('.')
  let l:code = ''

  if a:mode ==# 'v'
    let l:save_reg = getreg('v')
    let l:save_type = getregtype('v')
    try
      normal! gv"vy
      let l:code = getreg('v')
    finally
      call setreg('v', l:save_reg, l:save_type)
    endtry
    let l:curline = line("'<")
    let l:m = matchstr(l:code, '\<\%(func\|function\|def\|fn\|public\|protected\|private\)\s\+\%(([^)]*)\s*\)\?\zs\w\+\ze\s*(')
    if !empty(l:m)
      let l:symbol = l:m
    endif
  else
    let l:start = max([1, l:curline - 8])
    let l:end = min([line('$'), l:curline + 45])
    let l:code = join(getline(l:start, l:end), "\n")
  endif

  return {
    \ 'cwd': l:cwd,
    \ 'file': l:rel_file,
    \ 'line': l:curline,
    \ 'symbol': l:symbol,
    \ 'code': l:code,
    \ }
endfunction

function! s:replace_marker(bufnr, marker, new_lines) abort
  if !bufexists(a:bufnr)
    return
  endif
  let l:lines = getbufline(a:bufnr, 1, '$')
  let l:idx = index(l:lines, a:marker)
  let l:out = empty(a:new_lines) ? ['(无返回内容)'] : a:new_lines
  if l:idx >= 0
    let l:lnum = l:idx + 1
    call setbufline(a:bufnr, l:lnum, l:out[0])
    if len(l:out) > 1
      call appendbufline(a:bufnr, l:lnum, l:out[1:])
    endif
  else
    call appendbufline(a:bufnr, '$', l:out)
  endif
endfunction

function! s:finish_job(ctx) abort
  if !a:ctx.closed || !a:ctx.exited || a:ctx.done
    return
  endif
  let a:ctx.done = 1

  try
    if filereadable(a:ctx.req_file)
      call delete(a:ctx.req_file)
    endif
  catch
  endtry

  let l:bufnr = a:ctx.bufnr
  let l:raw = join(a:ctx.stdout, "\n")
  let l:res = {}
  try
    let l:res = json_decode(l:raw)
  catch
  endtry

  if type(l:res) == type({}) && get(l:res, 'ok', v:false)
    let l:answer = get(l:res, 'answer', '')
    let l:sid = get(l:res, 'session_id', '')
    let l:options = get(l:res, 'options', [])
    if type(l:options) != type([])
      let l:options = []
    endif
    let l:lines = split(l:answer, "\n", 1)
    if !empty(l:options)
      call add(l:lines, '')
      call add(l:lines, '> 💡 **快捷选项**（按数字键 `1`~`' . len(l:options) . '` 直接追问，按 `o` 弹窗单选/多选，或光标移到选项行按 `Enter`）：')
      for l:idx in range(len(l:options))
        call add(l:lines, printf('> `[%d]` %s', l:idx + 1, l:options[l:idx]))
      endfor
    endif
    call s:replace_marker(l:bufnr, a:ctx.marker, l:lines)
    if bufexists(l:bufnr)
      let l:state = getbufvar(l:bufnr, 'herdr_ai_state', {})
      if type(l:state) == type({})
        let l:state.session_id = empty(l:sid) ? get(l:state, 'session_id', '') : l:sid
        let l:rec_id = get(l:res, 'record_id', '')
        if !empty(l:rec_id)
          let l:state.record_id = l:rec_id
        endif
        let l:state.options = l:options
        let l:state.busy = 0
        call setbufvar(l:bufnr, 'herdr_ai_state', l:state)
      endif
    endif
    redraw
    if !empty(l:options)
      echomsg printf('✅ AI (%s) 分析完成（已存至 .vim-ai）：按 1~%d 或 o 选快捷项，a 追问，R 重诊，q 关闭', a:ctx.agent, len(l:options))
    else
      echomsg printf('✅ AI (%s) 分析完成（已存至 .vim-ai）：按 a 追问，R 重诊，q 关闭 Tab', a:ctx.agent)
    endif
  else
    let l:err = type(l:res) == type({}) && has_key(l:res, 'error')
          \ ? l:res.error
          \ : (empty(a:ctx.stderr) ? l:raw : join(a:ctx.stderr, "\n"))
    if empty(l:err)
      let l:err = '命令执行失败，exit=' . a:ctx.status
    endif
    let l:err_lines = ['> ❌ **调用失败**：'] + map(split(l:err, "\n"), '"> " . v:val')
    call s:replace_marker(l:bufnr, a:ctx.marker, l:err_lines)
    if bufexists(l:bufnr)
      let l:state = getbufvar(l:bufnr, 'herdr_ai_state', {})
      if type(l:state) == type({})
        let l:state.busy = 0
        call setbufvar(l:bufnr, 'herdr_ai_state', l:state)
      endif
    endif
    redraw
    echohl ErrorMsg | echomsg 'AI 调用失败: ' . split(l:err, "\n")[0] | echohl None
  endif
endfunction

function! s:on_job_close(ctx) abort
  let a:ctx.closed = 1
  call s:finish_job(a:ctx)
endfunction

function! s:on_job_exit(ctx, status) abort
  let a:ctx.exited = 1
  let a:ctx.status = a:status
  call s:finish_job(a:ctx)
endfunction

function! s:launch_job(bufnr, req, marker) abort
  if !executable('python3') || !filereadable(s:script_path)
    call s:replace_marker(a:bufnr, a:marker, ['> ❌ 未找到 `python3` 或 `' . s:script_path . '`'])
    return
  endif
  let l:req_file = tempname() . '.json'
  call writefile([json_encode(a:req)], l:req_file)

  let l:ctx = {
    \ 'bufnr': a:bufnr,
    \ 'req_file': l:req_file,
    \ 'marker': a:marker,
    \ 'agent': a:req.agent,
    \ 'stdout': [],
    \ 'stderr': [],
    \ 'closed': 0,
    \ 'exited': 0,
    \ 'done': 0,
    \ 'status': 0,
    \ }
  call job_start(['python3', s:script_path, l:req_file], {
    \ 'out_cb': {ch, msg -> add(l:ctx.stdout, msg)},
    \ 'err_cb': {ch, msg -> add(l:ctx.stderr, msg)},
    \ 'close_cb': {ch -> s:on_job_close(l:ctx)},
    \ 'exit_cb': {job, status -> s:on_job_exit(l:ctx, status)},
    \ })
endfunction

function! s:bind_ai_tab_keys() abort
  nnoremap <buffer> <silent> a :call herdr_ai#followup()<CR>
  nnoremap <buffer> <silent> <leader>ar :call herdr_ai#followup()<CR>
  nnoremap <buffer> <silent> o :call herdr_ai#pick_options()<CR>
  nnoremap <buffer> <silent> R :call herdr_ai#rediagnose()<CR>
  nnoremap <buffer> <silent> <CR> :call herdr_ai#enter_action()<CR>
  for l:n in range(1, 9)
    execute printf('nnoremap <buffer> <silent> %d :call herdr_ai#choose_option(%d)<CR>', l:n, l:n)
  endfor
  nnoremap <buffer> <silent> q :if tabpagenr('$') > 1 <Bar> tabclose <Bar> else <Bar> close <Bar> endif<CR>
endfunction

function! s:open_ai_tab(ctx, agent) abort
  let g:herdr_ai_last_agent = a:agent
  let s:tab_seq += 1
  let l:title = empty(a:ctx.symbol) ? 'AI' : a:ctx.symbol
  let l:safe_title = substitute(l:title, '[^A-Za-z0-9_.-]', '_', 'g')
  tabnew
  setlocal buftype=nofile bufhidden=wipe noswapfile
  setlocal filetype=markdown wrap linebreak conceallevel=0
  if !empty(a:ctx.cwd) && isdirectory(a:ctx.cwd)
    execute 'silent! lcd' fnameescape(a:ctx.cwd)
  endif
  silent! execute 'file AI://' . fnameescape(l:safe_title) . '-' . s:tab_seq

  let l:bufnr = bufnr('%')
  let l:marker = '<!-- HERDR_AI_LOADING_' . s:tab_seq . '_0 -->'
  let l:header = [
    \ '# AI 代码分析：`' . l:title . '`',
    \ '- **Agent**: `' . a:agent . '`  |  **位置**: `' . a:ctx.file . ':' . a:ctx.line . '`',
    \ '- **快捷键**: `1`~`9` 直选快捷项  |  `o` 弹窗单选/多选  |  `a`/`<Space>ar` 自由追问  |  `R` 重新诊断  |  `Enter`/`gf` 跳转文件或选项  |  `q` 关闭 Tab',
    \ '',
    \ '---',
    \ '',
    \ '### 1. 作用 / 用法 / 项目角色 / 调用层级分析',
    \ '',
    \ l:marker,
    \ ]
  call setline(1, l:header)

  let b:herdr_ai_state = {
    \ 'agent': a:agent,
    \ 'session_id': '',
    \ 'record_id': '',
    \ 'cwd': a:ctx.cwd,
    \ 'file': a:ctx.file,
    \ 'line': a:ctx.line,
    \ 'symbol': a:ctx.symbol,
    \ 'code': get(a:ctx, 'code', ''),
    \ 'options': [],
    \ 'turn': 0,
    \ 'busy': 1,
    \ }

  call s:bind_ai_tab_keys()

  " 替换占位符显示加载提示，保留精确 marker 用于回调匹配
  let l:loading_text = printf('> 🤖 正在向 [%s] 询问 `%s`，请稍候（可先切回代码 Tab）...', a:agent, l:title)
  call setbufline(l:bufnr, len(l:header), l:loading_text)

  let l:req = extend(copy(a:ctx), { 'agent': a:agent })
  call s:launch_job(l:bufnr, l:req, l:loading_text)
endfunction

function! s:open_history_record(rec, ctx) abort
  let s:tab_seq += 1
  let l:title = empty(get(a:rec, 'symbol', '')) ? 'AI' : a:rec.symbol
  let l:safe_title = substitute(l:title, '[^A-Za-z0-9_.-]', '_', 'g')
  tabnew
  setlocal buftype=nofile bufhidden=wipe noswapfile
  setlocal filetype=markdown wrap linebreak conceallevel=0
  if !empty(a:ctx.cwd) && isdirectory(a:ctx.cwd)
    execute 'silent! lcd' fnameescape(a:ctx.cwd)
  endif
  silent! execute 'file AI://' . fnameescape(l:safe_title) . '-hist-' . s:tab_seq

  let l:md_path = get(a:rec, 'md_path', '')
  let l:lines = filereadable(l:md_path) ? readfile(l:md_path) : ['(历史诊断文件不存在: ' . l:md_path . ')']
  call setline(1, l:lines)

  let b:herdr_ai_state = {
    \ 'agent': get(a:rec, 'agent', 'agy'),
    \ 'session_id': get(a:rec, 'session_id', ''),
    \ 'record_id': get(a:rec, 'id', ''),
    \ 'cwd': a:ctx.cwd,
    \ 'file': get(a:rec, 'file', a:ctx.file),
    \ 'line': get(a:rec, 'line', a:ctx.line),
    \ 'symbol': l:title,
    \ 'code': get(a:ctx, 'code', ''),
    \ 'options': get(a:rec, 'options', []),
    \ 'turn': get(a:rec, 'turns', 0),
    \ 'busy': 0,
    \ }

  call s:bind_ai_tab_keys()
  redraw
  echomsg printf('📂 已打开本地历史诊断 [%s | %s]（零算力消耗）：按 1~9/o/a 可继续追问，按 R 重新诊断，q 关闭', get(a:rec, 'agent', ''), get(a:rec, 'updated_at', ''))
endfunction

function! herdr_ai#rediagnose() abort
  if !exists('b:herdr_ai_state')
    return
  endif
  let l:st = b:herdr_ai_state
  let l:ctx = {
    \ 'cwd': l:st.cwd,
    \ 'file': l:st.file,
    \ 'line': l:st.line,
    \ 'symbol': l:st.symbol,
    \ 'code': get(l:st, 'code', ''),
    \ }
  if empty(l:ctx.code) && filereadable(l:st.cwd . '/' . l:st.file)
    let l:flines = readfile(l:st.cwd . '/' . l:st.file)
    let l:s = max([0, l:st.line - 9])
    let l:e = min([len(l:flines) - 1, l:st.line + 44])
    if l:s <= l:e
      let l:ctx.code = join(l:flines[l:s : l:e], "\n")
    endif
  endif
  call s:pick_agent(l:ctx)
endfunction

function! s:send_followup_text(question) abort
  if !exists('b:herdr_ai_state')
    echohl WarningMsg | echom '当前窗口不是 AI 分析 Tab' | echohl None
    return
  endif
  let l:state = b:herdr_ai_state
  if get(l:state, 'busy', 0)
    echohl WarningMsg | echom 'AI 正在思考上一条问题，请稍候...' | echohl None
    return
  endif
  let l:q = trim(a:question)
  if empty(l:q)
    return
  endif

  let l:state.turn += 1
  let l:state.busy = 1
  let l:state.options = []
  let b:herdr_ai_state = l:state

  let l:bufnr = bufnr('%')
  let l:preview_q = strcharpart(substitute(l:q, '\r\?\n.*', ' ...', ''), 0, 24)
  let l:loading_text = printf('> 🤖 [追问 #%d] 正在思考 "%s" ...', l:state.turn, l:preview_q)
  let l:q_lines = split(l:q, '\r\?\n', 1)
  let l:append_lines = ['', '---', '', '### 追问 #' . l:state.turn . '：' . l:q_lines[0]]
  if len(l:q_lines) > 1
    call extend(l:append_lines, l:q_lines[1:])
  endif
  call extend(l:append_lines, ['', l:loading_text])
  call appendbufline(l:bufnr, '$', l:append_lines)
  normal! G

  let l:req = {
    \ 'agent': l:state.agent,
    \ 'session_id': get(l:state, 'session_id', ''),
    \ 'record_id': get(l:state, 'record_id', ''),
    \ 'cwd': l:state.cwd,
    \ 'file': l:state.file,
    \ 'line': l:state.line,
    \ 'symbol': l:state.symbol,
    \ 'question': l:q,
    \ }
  call s:launch_job(l:bufnr, l:req, l:loading_text)
endfunction

function! herdr_ai#followup() abort
  if !exists('b:herdr_ai_state')
    echohl WarningMsg | echom '当前窗口不是 AI 分析 Tab' | echohl None
    return
  endif
  let l:state = b:herdr_ai_state
  if get(l:state, 'busy', 0)
    echohl WarningMsg | echom 'AI 正在思考上一条问题，请稍候...' | echohl None
    return
  endif
  let l:q = input('追问 (' . l:state.agent . ')> ')
  call s:send_followup_text(l:q)
endfunction

function! herdr_ai#choose_option(idx) abort
  if !exists('b:herdr_ai_state')
    return
  endif
  let l:opts = get(b:herdr_ai_state, 'options', [])
  if a:idx < 1 || a:idx > len(l:opts)
    echohl WarningMsg | echom printf('当前没有第 %d 个快捷选项（共有 %d 项）', a:idx, len(l:opts)) | echohl None
    return
  endif
  call s:send_followup_text(printf('我选择第 %d 项：%s', a:idx, l:opts[a:idx - 1]))
endfunction

function! s:options_sink(lines) abort
  if empty(a:lines)
    return
  endif
  let l:chosen = []
  let l:want_custom = 0
  for l:ln in a:lines
    let l:parts = split(l:ln, "\t")
    if empty(l:parts)
      continue
    endif
    if l:parts[0] ==# '__CUSTOM__'
      let l:want_custom = 1
      continue
    endif
    let l:txt = substitute(get(l:parts, 1, l:parts[0]), '^\[\d\+\]\s*', '', '')
    if !empty(l:txt)
      call add(l:chosen, l:txt)
    endif
  endfor
  if l:want_custom && exists('b:herdr_ai_state')
    let l:custom_q = trim(input('自定义追问 (' . b:herdr_ai_state.agent . ')> '))
    if !empty(l:custom_q)
      call add(l:chosen, l:custom_q)
    endif
  endif
  if len(l:chosen) == 1
    call s:send_followup_text(l:chosen[0])
  elseif len(l:chosen) > 1
    call s:send_followup_text("请一并解答以下几点：\n- " . join(l:chosen, "\n- "))
  endif
endfunction

function! herdr_ai#pick_options() abort
  if !exists('b:herdr_ai_state')
    return
  endif
  let l:opts = get(b:herdr_ai_state, 'options', [])
  let l:items = []
  for l:i in range(len(l:opts))
    call add(l:items, printf("%d\t[%d] %s", l:i + 1, l:i + 1, l:opts[l:i]))
  endfor
  call add(l:items, "__CUSTOM__\t[自定义输入追问...]")

  let l:spec = {
    \ 'source': l:items,
    \ 'sink*': function('s:options_sink'),
    \ 'options': [
    \   '--multi',
    \   '--delimiter', "\t",
    \   '--with-nth', '2..',
    \   '--tiebreak=index',
    \   '--prompt', '选择追问选项 (Tab 可多选)> ',
    \ ],
    \ }
  call fzf#run(fzf#wrap('herdr_ai_opts', l:spec, 0))
endfunction

function! herdr_ai#enter_action() abort
  let l:line = getline('.')
  " 1. 光标在快捷选项行: > `[1]` ...
  let l:m = matchlist(l:line, '^>\s*`\[\(\d\+\)\]`\s*\(.\+\)$')
  if !empty(l:m)
    call s:send_followup_text(printf('我选择第 %s 项：%s', l:m[1], trim(l:m[2])))
    return
  endif
  " 2. 光标在 Markdown 编号选项行: 1. ...
  let l:m2 = matchlist(l:line, '^\s*\d\+[\.\)、]\s\+\(.\+\)$')
  if !empty(l:m2) && l:m2[1] !~# '^\*\*\(具体作用\|使用方法\|在整个项目里的作用\|在项目中的作用\|调用的代码层级关系\)\*\*'
    call s:send_followup_text(substitute(l:m2[1], '\*\*', '', 'g'))
    return
  endif
  " 3. 光标在文件路径:行号上 -> 在前一个 Tab 或新分屏打开源码
  let l:fm = matchlist(l:line, '\([A-Za-z0-9_./-]\+\.[A-Za-z0-9]\+\):\(\d\+\)')
  if !empty(l:fm)
    let l:cwd = exists('b:herdr_ai_state') ? get(b:herdr_ai_state, 'cwd', getcwd()) : getcwd()
    let l:target = filereadable(l:fm[1]) ? l:fm[1] : (l:cwd . '/' . l:fm[1])
    if filereadable(l:target)
      execute 'botright split' fnameescape(l:target)
      call cursor(str2nr(l:fm[2]), 1)
      normal! zvzz
      return
    endif
  endif
  " 4. 回退到 gf
  silent! normal! gf
endfunction

function! s:pick_agent(ctx) abort
  let l:items = [
    \ "agy\tagy — Antigravity 无头会话（默认推荐，纯净 Markdown + 追问）",
    \ "claude\tclaude — Claude Code 无头会话（纯净 Markdown + 追问）",
    \ "codex\tcodex — Codex CLI 无头会话（纯净 Markdown + 追问）",
    \ ]

  if executable('python3') && filereadable(s:script_path)
    try
      let l:raw = system(printf('python3 %s --list-windows', shellescape(s:script_path)))
      let l:wins = json_decode(l:raw)
      if type(l:wins) == type([])
        for l:w in l:wins
          let l:mark = get(l:w, 'cwd', '') ==# a:ctx.cwd ? '★ 当前项目窗口: ' : 'Herdr 窗口: '
          call add(l:items, printf("%s\t%s%s", l:w.id, l:mark, l:w.label))
        endfor
      endif
    catch
    endtry
  endif

  let l:spec = {
    \ 'source': l:items,
    \ 'sink': {line -> s:open_ai_tab(a:ctx, split(line, "\t")[0])},
    \ 'options': [
    \   '--delimiter', "\t",
    \   '--with-nth', '2..',
    \   '--tiebreak=index',
    \   '--prompt', '选择 AI Agent (' . a:ctx.symbol . ')> ',
    \ ],
    \ }
  call fzf#run(fzf#wrap('herdr_ai', l:spec, 0))
endfunction

function! s:query_history(cwd, file, symbol) abort
  if !executable('python3') || !filereadable(s:script_path) || empty(a:cwd)
    return []
  endif
  try
    let l:cmd = printf('python3 %s --query-history %s %s %s',
          \ shellescape(s:script_path),
          \ shellescape(a:cwd),
          \ shellescape(a:file),
          \ shellescape(a:symbol))
    let l:raw = system(l:cmd)
    let l:data = json_decode(l:raw)
    return type(l:data) == type([]) ? l:data : []
  catch
    return []
  endtry
endfunction

function! s:history_or_new_sink(ctx, rec_map, default_agent, line) abort
  let l:parts = split(a:line, "\t")
  if empty(l:parts)
    return
  endif
  let l:key = l:parts[0]
  if l:key ==# 'NEW_DEFAULT'
    call s:open_ai_tab(a:ctx, a:default_agent)
  elseif l:key ==# 'NEW_PICK'
    call s:pick_agent(a:ctx)
  elseif has_key(a:rec_map, l:key)
    call s:open_history_record(a:rec_map[l:key], a:ctx)
  endif
endfunction

function! herdr_ai#ask(mode, pick_agent) abort
  let l:ctx = s:extract_context(a:mode)
  let l:default_agent = get(g:, 'herdr_ai_last_agent', get(g:, 'herdr_ai_default_agent', 'agy'))

  if !empty(l:ctx.symbol) && l:ctx.file !=# '[No Name]'
    let l:records = s:query_history(l:ctx.cwd, l:ctx.file, l:ctx.symbol)
    if !empty(l:records)
      let l:items = []
      let l:rec_map = {}
      for l:rec in l:records
        let l:id = 'HIST:' . l:rec.id
        let l:rec_map[l:id] = l:rec
        let l:turns = get(l:rec, 'turns', 0)
        let l:turn_tag = l:turns > 0 ? printf(' | 追问:%d', l:turns) : ''
        let l:disp = printf("📄 [历史诊断 %s | %s%s] 直接查看（免算力，可继续追问）",
              \ get(l:rec, 'updated_at', ''),
              \ get(l:rec, 'agent', 'agy'),
              \ l:turn_tag)
        call add(l:items, printf("%s\t%s\t%s", l:id, get(l:rec, 'md_path', '[No Name]'), l:disp))
      endfor
      if a:pick_agent
        call add(l:items, "NEW_PICK\t[No Name]\t🤖 [重新诊断 (选模型)] 选择 agy / claude / codex / Herdr窗口 重新分析")
        call add(l:items, printf("NEW_DEFAULT\t[No Name]\t🔄 [重新诊断] 使用默认/上次 Agent (%s) 重新分析", l:default_agent))
      else
        call add(l:items, printf("NEW_DEFAULT\t[No Name]\t🔄 [重新诊断] 使用默认/上次 Agent (%s) 重新分析", l:default_agent))
        call add(l:items, "NEW_PICK\t[No Name]\t🤖 [重新诊断 (选模型)] 选择 agy / claude / codex / Herdr窗口 重新分析")
      endif

      let l:spec = fzf#vim#with_preview({
        \ 'source': l:items,
        \ 'sink': {line -> s:history_or_new_sink(l:ctx, l:rec_map, l:default_agent, line)},
        \ 'placeholder': '{2}',
        \ 'options': [
        \   '-d', "\t",
        \   '--with-nth', '3..',
        \   '--tiebreak=index',
        \   '--prompt', printf('已存在 `%s` 诊断记录> ', l:ctx.symbol),
        \ ],
        \ })
      call fzf#run(fzf#wrap('herdr_ai_hist', l:spec, 0))
      return
    endif
  endif

  if a:pick_agent
    call s:pick_agent(l:ctx)
  else
    call s:open_ai_tab(l:ctx, l:default_agent)
  endif
endfunction

function! herdr_ai#browse_history() abort
  let l:cwd = s:resolve_current_cwd()
  let l:records = s:query_history(l:cwd, '', '')
  if empty(l:records)
    echohl WarningMsg | echom '当前项目 (.vim-ai) 暂无已保存的 AI 诊断记录' | echohl None
    return
  endif

  let l:items = []
  let l:rec_map = {}
  for l:rec in l:records
    let l:id = 'HIST:' . l:rec.id
    let l:rec_map[l:id] = l:rec
    let l:turns = get(l:rec, 'turns', 0)
    let l:turn_tag = l:turns > 0 ? printf(' | 追问:%d', l:turns) : ''
    let l:disp = printf("\x1b[36m%s:%d\x1b[0m :: \x1b[33m%s\x1b[0m  [%s | %s%s]",
          \ get(l:rec, 'file', ''),
          \ get(l:rec, 'line', 1),
          \ get(l:rec, 'symbol', ''),
          \ get(l:rec, 'agent', ''),
          \ get(l:rec, 'updated_at', ''),
          \ l:turn_tag)
    call add(l:items, printf("%s\t%s\t%s", l:id, get(l:rec, 'md_path', '[No Name]'), l:disp))
  endfor

  let l:ctx = { 'cwd': l:cwd, 'file': '', 'line': 1, 'symbol': '', 'code': '' }
  let l:spec = fzf#vim#with_preview({
    \ 'source': l:items,
    \ 'sink': {line -> s:open_history_record(l:rec_map[split(line, "\t")[0]], l:ctx)},
    \ 'placeholder': '{2}',
    \ 'options': [
    \   '--ansi',
    \   '-d', "\t",
    \   '--with-nth', '3..',
    \   '--tiebreak=index',
    \   '--prompt', '项目 AI 诊断历史 (.vim-ai)> ',
    \ ],
    \ })
  call fzf#run(fzf#wrap('herdr_ai_all_hist', l:spec, 0))
endfunction
