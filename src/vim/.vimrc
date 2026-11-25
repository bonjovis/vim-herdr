" ============================================================
"  ~/.vimrc  —  方案 B
"  vim-lsp + vim-lsp-settings  (代码跳转 / 引用 / 重命名)
"  fzf.vim + ripgrep           (文件 / 全文搜索)
"  gutentags + tagbar          (ctags 自动生成 + 符号大纲)
"  vim-sneak                   (文件内快速跳转)
" ============================================================

" ---------- 基础 ----------
set nocompatible

" Leader 键：空格。单独按空格作右移时会等待 timeoutlen（400ms），可自行调整
let mapleader = " "
set timeoutlen=400

filetype plugin indent on
syntax enable

set encoding=utf-8
set nonumber norelativenumber
set hidden
set mouse=a
set updatetime=300
set signcolumn=yes
set splitright splitbelow
set wildmenu wildmode=longest:full,full

" 缩进：默认 4 空格（Java/Go 通用；Vim 自带 ftplugin 会按语言覆盖）
set tabstop=4 shiftwidth=4 softtabstop=4 expandtab
set autoindent smartindent

" 搜索
set ignorecase smartcase incsearch hlsearch
set path+=**

" 补全菜单：不自动选中第一项
set completeopt=menu,menuone,noinsert,noselect

" 关闭备份/交换文件带来的噪音；开启跨会话持久化撤销（undofile）与外部修改静默热刷新（autoread）
set nobackup nowritebackup
set noswapfile
set autoread

let s:vim_undo_dir = expand('~/.cache/vim/undo')
if !isdirectory(s:vim_undo_dir)
  silent! call mkdir(s:vim_undo_dir, 'p', 0700)
endif
if isdirectory(s:vim_undo_dir) && has('persistent_undo')
  let &undodir = s:vim_undo_dir
  set undofile
endif

" 重新打开文件时自动回到上次退出的光标行（排除 git commit / rebase 临时文件）
augroup vim_restore_cursor
  autocmd!
  autocmd BufReadPost * if &buftype ==# '' && &filetype !~# '^\(commit\|gitcommit\|gitrebase\)$'
        \ && line("'\"") > 1 && line("'\"") <= line('$')
        \ | execute "normal! g`\"" | endif
augroup END

" 外部智能体（Claude / Agy / Codex）修改文件后，切回 Vim 或停顿瞬间自动静默刷新（无未保存冲突时不弹 W11）
augroup vim_auto_reload
  autocmd!
  autocmd FocusGained,BufEnter,CursorHold,CursorHoldI *
        \ if mode() !~# '^[c!t]' && getcmdwintype() ==# '' && &buftype ==# '' | silent! checktime | endif
  autocmd FileChangedShellPost * echohl WarningMsg | echo '🔄 检测到外部修改，已自动加载最新文件内容' | echohl None
augroup END

" 滚动时保留上下文
set scrolloff=5

" ---------- 插件 ----------
call plug#begin('~/.vim/plugged')

Plug 'prabirshrestha/vim-lsp'
Plug 'mattn/vim-lsp-settings'
Plug 'junegunn/fzf'
Plug 'junegunn/fzf.vim'
Plug 'ludovicchabant/vim-gutentags'
Plug 'preservim/tagbar'
Plug 'lambdalisue/fern.vim'
Plug 'justinmk/vim-sneak'
Plug 'airblade/vim-gitgutter'

call plug#end()

" ============================================================
"  vim-lsp
" ============================================================

" Java(LSP jdtls) 需要 JDK 17+；本机 PATH 上的 java 是 1.8，这里显式指定 21。
" 注意：这会影响 Vim 内 :! 子进程使用的 java。
if isdirectory('/usr/lib/jvm/java-21')
  let $JAVA_HOME = '/usr/lib/jvm/java-21'
  let $PATH = '/usr/lib/jvm/java-21/bin:' . $PATH
endif

let g:lsp_diagnostics_enabled = 1
let g:lsp_diagnostics_echo_cursor = 1
let g:lsp_diagnostics_echo_delay = 500
let g:lsp_diagnostics_signs_enabled = 1
let g:lsp_document_code_action_signs_enabled = 0
let g:lsp_diagnostics_virtual_text_enabled = 0
let g:lsp_format_sync_timeout = 1000

" 若 LSP server 启动时当前 buffer 是 fern 之类的虚拟 buffer（expand('%:p') 是 URI），
" vim-lsp-settings 会把这个 URI 误当作项目根目录，导致 server 初始化失败。
" 这种情况回退到 Vim 的工作目录（通常就是项目根）。
function! s:lsp_root_uri(name, key) abort
  if expand('%:p') =~# '^\a\w*://'
    return lsp#utils#path_to_uri(getcwd())
  endif
  return lsp_settings#root_uri(a:name)
endfunction

let g:lsp_settings = {
\ '*': {
\   'root_uri': function('s:lsp_root_uri'),
\ },
\}

augroup lsp_config
  autocmd!
  autocmd User lsp_buffer_enabled call s:on_lsp_buffer_enabled()
augroup END

function! s:on_lsp_buffer_enabled() abort
  setlocal omnifunc=lsp#complete
  if exists('+tagfunc')
    setlocal tagfunc=lsp#tagfunc   " Ctrl-] 优先走 LSP，失败再回退 ctags
  endif

  nmap <buffer> gd          <plug>(lsp-definition)
  nmap <buffer> gD          <plug>(lsp-declaration)
  nmap <buffer> gr          :<C-u>call <SID>lsp_fzf_location('references', 'References (调用路径)')<CR>
  nmap <buffer> gi          :<C-u>call <SID>lsp_fzf_location('implementation', 'Implementations (具体实现)')<CR>
  nmap <buffer> gy          <plug>(lsp-type-definition)
  nmap <buffer> K           <plug>(lsp-hover)
  nmap <buffer> <C-k>       <plug>(lsp-hover)
  nmap <buffer> <leader>ci  :<C-u>call <SID>lsp_fzf_call_hierarchy('incoming')<CR>
  nmap <buffer> <leader>cg  :<C-u>call <SID>lsp_fzf_call_hierarchy('outgoing')<CR>
  nmap <buffer> <leader>ct  :<C-u>LspAddTreeCallHierarchyIncoming<CR>
  nmap <buffer> <leader>rn  <plug>(lsp-rename)
  nmap <buffer> <leader>ca  <plug>(lsp-code-action)
  nmap <buffer> <leader>d   <plug>(lsp-document-symbol)
  nmap <buffer> <leader>s   <plug>(lsp-workspace-symbol)
  nmap <buffer> <leader>lf  <plug>(lsp-document-format)
  nmap <buffer> ]g          <plug>(lsp-next-diagnostic)
  nmap <buffer> [g          <plug>(lsp-previous-diagnostic)
  nmap <buffer> <leader>pd  <plug>(lsp-peek-definition)
  nmap <buffer> <leader>pr  <plug>(lsp-peek-references)
endfunction

" ============================================================
"  LSP + FZF 调用路径 / 具体实现 交互式预览弹窗
" ============================================================
function! s:find_enclosing_func(lines, lnum) abort
  if empty(a:lines) || a:lnum <= 1
    return ''
  endif
  let l:start = min([len(a:lines) - 1, a:lnum - 1])
  let l:stop  = max([0, a:lnum - 180])
  for l:idx in range(l:start, l:stop, -1)
    let l:line = a:lines[l:idx]
    " Go: func (s *Service) MethodName( 或 func FuncName(
    let l:m = matchstr(l:line, '^\s*func\s\+\%(([^)]*)\s*\)\?\zs\w\+\ze\s*(')
    if !empty(l:m)
      return l:m
    endif
    " PHP / JS / TS: function methodName(
    let l:m = matchstr(l:line, '\<function\s\+&\?\s*\zs\w\+\ze\s*(')
    if !empty(l:m)
      return l:m
    endif
    " Java / TS / PHP class method: public/protected/private/static/async ... methodName(
    let l:m = matchstr(l:line, '^\s*\%(public\|protected\|private\|static\|async\|synchronized\|final\|abstract\|\s\)\+[A-Za-z0-9_<>\[\],?.\s]\+\s\+\zs\w\+\ze\s*(')
    if !empty(l:m) && l:m !~# '^\(if\|for\|while\|switch\|catch\|return\|new\)$'
      return l:m
    endif
  endfor
  return ''
endfunction

function! s:lsp_fzf_sink(line) abort
  let l:parts = split(a:line, "\t")
  if empty(l:parts)
    return
  endif
  let l:m = matchlist(l:parts[0], '^\(.\+\):\(\d\+\):\(\d\+\)$')
  if empty(l:m)
    return
  endif
  let l:file = l:m[1]
  let l:lnum = str2nr(l:m[2])
  let l:col  = str2nr(l:m[3])
  call lsp#utils#tagstack#_update()
  if fnamemodify(expand('%:p'), ':p') !=# fnamemodify(l:file, ':p')
    execute 'edit' fnameescape(l:file)
  endif
  call cursor(l:lnum, l:col)
  normal! zvzz
endfunction

function! s:lsp_fzf_open(title, items) abort
  if empty(a:items)
    call lsp#utils#error('未找到结果: ' . a:title)
    return
  endif
  call lsp#ui#vim#utils#setqflist(a:items, a:title)
  let l:cache = {}
  let l:source = []
  for l:item in a:items
    let l:file = get(l:item, 'filename', '')
    if empty(l:file)
      continue
    endif
    let l:lnum = max([1, get(l:item, 'lnum', 1)])
    let l:col  = max([1, get(l:item, 'col', 1)])
    if !has_key(l:cache, l:file)
      let l:cache[l:file] = filereadable(l:file) ? readfile(l:file) : []
    endif
    let l:flines = l:cache[l:file]
    let l:code = l:lnum <= len(l:flines) ? trim(l:flines[l:lnum - 1]) : trim(get(l:item, 'text', ''))
    let l:caller = get(l:item, 'caller', '')
    if empty(l:caller)
      let l:caller = s:find_enclosing_func(l:flines, l:lnum)
    endif
    let l:rel = fnamemodify(l:file, ':~:.')
    let l:tag = empty(l:caller) ? '' : printf("\x1b[33m[%s]\x1b[0m ", l:caller)
    let l:display = printf("\x1b[36m%s\x1b[0m:\x1b[32m%d\x1b[0m:%d: %s%s", l:rel, l:lnum, l:col, l:tag, l:code)
    call add(l:source, printf("%s:%d:%d\t%d\t%s", l:file, l:lnum, l:col, l:lnum, l:display))
  endfor
  let l:spec = fzf#vim#with_preview({
    \ 'source': l:source,
    \ 'sink': function('s:lsp_fzf_sink'),
    \ 'placeholder': '{1}',
    \ 'options': [
    \   '--ansi',
    \   '-d', "\t",
    \   '--with-nth', '3..',
    \   '--tiebreak=index',
    \   '--prompt', a:title . '> ',
    \   '--preview-window', '+{2}-/2',
    \ ],
    \ })
  call fzf#run(fzf#wrap('lsp_fzf', l:spec, 0))
endfunction

function! s:lsp_fzf_location(method, title) abort
  let l:op = substitute(a:method, '\u', ' \l\0', 'g')
  let l:cap = printf('lsp#capabilities#has_%s_provider(v:val)', substitute(l:op, ' ', '_', 'g'))
  let l:servers = filter(lsp#get_allowed_servers(), l:cap)
  if empty(l:servers)
    call lsp#utils#error('当前语言 LSP 不支持: ' . a:title)
    return
  endif
  let l:cmd_id = lsp#_new_command()
  let l:ctx = { 'counter': len(l:servers), 'list': [], 'cmd_id': l:cmd_id, 'title': a:title }
  let l:params = {
    \ 'textDocument': lsp#get_text_document_identifier(),
    \ 'position': lsp#get_position(),
    \ }
  if a:method ==# 'references'
    let l:params['context'] = { 'includeDeclaration': v:true }
  endif
  for l:server in l:servers
    call lsp#send_request(l:server, {
      \ 'method': 'textDocument/' . a:method,
      \ 'params': l:params,
      \ 'on_notification': function('s:handle_lsp_fzf_location', [l:ctx, l:server]),
      \ })
  endfor
  echo '正在查询 ' . a:title . ' ...'
endfunction

function! s:handle_lsp_fzf_location(ctx, server, data) abort
  if a:ctx['cmd_id'] != lsp#_last_command()
    return
  endif
  let a:ctx['counter'] -= 1
  if !lsp#client#is_error(a:data['response']) && has_key(a:data['response'], 'result')
    let a:ctx['list'] += lsp#utils#location#_lsp_to_vim_list(a:data['response']['result'])
  endif
  if a:ctx['counter'] == 0
    call s:lsp_fzf_open(a:ctx['title'], a:ctx['list'])
  endif
endfunction

function! s:lsp_fzf_call_hierarchy(dir) abort
  let l:servers = filter(lsp#get_allowed_servers(), 'lsp#capabilities#has_call_hierarchy_provider(v:val)')
  if empty(l:servers)
    if a:dir ==# 'incoming'
      call s:lsp_fzf_location('references', 'References (调用路径)')
    else
      call lsp#utils#error('当前语言 LSP 不支持 Call Hierarchy')
    endif
    return
  endif
  let l:cmd_id = lsp#_new_command()
  let l:ctx = {
    \ 'dir': a:dir,
    \ 'method': a:dir ==# 'incoming' ? 'incomingCalls' : 'outgoingCalls',
    \ 'key': a:dir ==# 'incoming' ? 'from' : 'to',
    \ 'title': a:dir ==# 'incoming' ? 'Incoming Calls (谁调用了它)' : 'Outgoing Calls (它调用了谁)',
    \ 'prep_counter': len(l:servers),
    \ 'call_counter': 0,
    \ 'list': [],
    \ 'cmd_id': l:cmd_id,
    \ }
  for l:server in l:servers
    call lsp#send_request(l:server, {
      \ 'method': 'textDocument/prepareCallHierarchy',
      \ 'params': {
      \   'textDocument': lsp#get_text_document_identifier(),
      \   'position': lsp#get_position(),
      \ },
      \ 'on_notification': function('s:handle_lsp_fzf_prep_call', [l:ctx, l:server]),
      \ })
  endfor
  echo '正在查询 ' . l:ctx['title'] . ' ...'
endfunction

function! s:handle_lsp_fzf_prep_call(ctx, server, data) abort
  if a:ctx['cmd_id'] != lsp#_last_command()
    return
  endif
  let a:ctx['prep_counter'] -= 1
  let l:res = get(a:data['response'], 'result', [])
  if !lsp#client#is_error(a:data['response']) && type(l:res) == type([]) && !empty(l:res)
    for l:item in l:res
      let a:ctx['call_counter'] += 1
      call lsp#send_request(a:server, {
        \ 'method': 'callHierarchy/' . a:ctx['method'],
        \ 'params': { 'item': l:item },
        \ 'on_notification': function('s:handle_lsp_fzf_calls', [a:ctx, a:server]),
        \ })
    endfor
  endif
  if a:ctx['prep_counter'] == 0 && a:ctx['call_counter'] == 0
    if a:ctx['dir'] ==# 'incoming'
      call s:lsp_fzf_location('references', 'References (调用路径)')
    else
      call lsp#utils#error('未找到调用层级: ' . a:ctx['title'])
    endif
  endif
endfunction

function! s:handle_lsp_fzf_calls(ctx, server, data) abort
  if a:ctx['cmd_id'] != lsp#_last_command()
    return
  endif
  let a:ctx['call_counter'] -= 1
  let l:res = get(a:data['response'], 'result', [])
  if !lsp#client#is_error(a:data['response']) && type(l:res) == type([])
    for l:entry in l:res
      let l:target = get(l:entry, a:ctx['key'], {})
      let l:uri = get(l:target, 'uri', '')
      if !lsp#utils#is_file_uri(l:uri)
        continue
      endif
      let l:path = lsp#utils#uri_to_path(l:uri)
      let l:ranges = get(l:entry, 'fromRanges', [])
      let l:range = (!empty(l:ranges) && a:ctx['dir'] ==# 'incoming') ? l:ranges[0] : get(l:target, 'selectionRange', get(l:target, 'range', {}))
      let l:loc = lsp#utils#range#lsp_to_vim_loc(l:path, l:range)
      let l:caller = get(l:target, 'name', '')
      call add(a:ctx['list'], extend({
        \ 'filename': l:path,
        \ 'caller': l:caller,
        \ 'text': l:caller,
        \ }, l:loc))
    endfor
  endif
  if a:ctx['prep_counter'] == 0 && a:ctx['call_counter'] == 0
    if empty(a:ctx['list']) && a:ctx['dir'] ==# 'incoming'
      call s:lsp_fzf_location('references', 'References (调用路径)')
    else
      call s:lsp_fzf_open(a:ctx['title'], a:ctx['list'])
    endif
  endif
endfunction

" ============================================================
"  fzf + ripgrep
" ============================================================
let $FZF_DEFAULT_COMMAND = 'rg --files --hidden --follow --glob "!.git/*" --glob "!node_modules/*"'
let g:fzf_layout = { 'down': '~40%' }
let g:fzf_preview_window = ['right,50%,<70(up,40%)', 'ctrl-/']

" 找项目根：逐级向上查找最近的 .git 或构建文件标记（避免跨出当前仓库误匹配上级目录的散落文件）
function! s:project_root(path) abort
  let l:dir = isdirectory(a:path) ? fnamemodify(a:path, ':p:h') : fnamemodify(a:path, ':p:h')
  if empty(l:dir)
    let l:dir = getcwd()
  endif
  let l:home = fnamemodify(expand('~'), ':p:h')
  let l:markers = ['.git', 'go.mod', 'pom.xml', 'build.gradle', 'build.gradle.kts', 'package.json', 'composer.json', '.hg', '.svn']
  let l:cur = l:dir
  while !empty(l:cur) && l:cur !=# '/' && l:cur !=# l:home
    for l:m in l:markers
      if isdirectory(l:cur . '/' . l:m) || filereadable(l:cur . '/' . l:m)
        return l:cur
      endif
    endfor
    let l:parent = fnamemodify(l:cur, ':h')
    if l:parent ==# l:cur
      break
    endif
    let l:cur = l:parent
  endwhile
  return l:dir
endfunction

" 全文搜索：在 fern 文件树里用树根，普通文件用项目根，避免 rg 搜错目录
function! s:current_search_root() abort
  let l:root = ''
  if &filetype ==# 'fern'
    try
      let l:root = fern#helper#new().sync.get_root_node()._path
    catch
    endtry
  else
    let l:path = expand('%:p')
    " 无名 buffer 直接用工作目录，不再向上找标记（避免搜到无关的上级目录）
    let l:root = empty(l:path) ? getcwd() : s:project_root(l:path)
  endif
  return l:root
endfunction

function! s:rg_project() abort
  let l:root = s:current_search_root()
  if !empty(l:root) && isdirectory(l:root)
    execute 'lcd' fnameescape(l:root)
  endif
  Rg
endfunction

" 清理残留的 fzf 终端弹窗并聚焦回主代码编辑窗口
function! HerdrCleanMainWin() abort
  for l:w in range(winnr('$'), 1, -1)
    let l:b = winbufnr(l:w)
    if getbufvar(l:b, '&buftype') ==# 'terminal' || getbufvar(l:b, '&filetype') ==# 'fzf'
      silent! execute l:b . 'bwipeout!'
    endif
  endfor
  if &buftype !=# '' || &filetype =~# '^\(fern\|tagbar\|qf\)$'
    silent! wincmd p
  endif
  if &buftype !=# '' || &filetype =~# '^\(fern\|tagbar\|qf\)$'
    for l:w in range(1, winnr('$'))
      let l:b = winbufnr(l:w)
      if getbufvar(l:b, '&buftype') ==# '' && getbufvar(l:b, '&filetype') !~# '^\(fern\|tagbar\|qf\)$'
        execute l:w . 'wincmd w'
        break
      endif
    endfor
  endif
  set hidden
endfunction

" 在指定目录下对给定文字进行全文搜索（FZF 弹窗 + 右侧预览）
function! HerdrSearchInDir(dir, query) abort
  call HerdrCleanMainWin()
  let l:dir = !empty(a:dir) && isdirectory(a:dir) ? a:dir : s:current_search_root()
  if !empty(l:dir) && isdirectory(l:dir)
    execute 'silent! cd' fnameescape(l:dir)
    execute 'silent! lcd' fnameescape(l:dir)
  endif
  let l:q = trim(a:query)
  if empty(l:q)
    Rg
    return
  endif
  let l:cmd = 'rg --column --line-number --no-heading --color=always --smart-case -F -- ' . fzf#shellescape(l:q)
  call fzf#vim#grep(l:cmd, 1, fzf#vim#with_preview({
    \ 'options': ['--prompt', 'Search [' . l:q . ']> '],
    \ }), 0)
endfunction

function! HerdrSearchFromFile(json_file) abort
  if !filereadable(a:json_file)
    return
  endif
  try
    let l:data = json_decode(join(readfile(a:json_file), "\n"))
    call HerdrSearchInDir(get(l:data, 'dir', ''), get(l:data, 'query', ''))
  catch
  endtry
endfunction

function! s:rg_visual() abort
  let l:save_reg = getreg('v')
  let l:save_type = getregtype('v')
  try
    normal! gv"vy
    let l:text = getreg('v')
  finally
    call setreg('v', l:save_reg, l:save_type)
  endtry
  let l:lines = filter( map(split(l:text, "\n"), 'trim(v:val)'), '!empty(v:val)' )
  let l:q = empty(l:lines) ? '' : l:lines[0]
  call HerdrSearchInDir(s:current_search_root(), l:q)
endfunction

" 最近访问项目记录与多项目一键切换 (<leader>fp)
let s:recent_projects_file = expand('~/.cache/vim/recent_projects.txt')

function! s:record_recent_project() abort
  if &buftype !=# '' || &filetype =~# '^\(fern\|tagbar\|qf\|help\)$'
    return
  endif
  let l:p = expand('%:p')
  let l:root = empty(l:p) ? '' : s:project_root(l:p)
  if empty(l:root) || !isdirectory(l:root) || l:root ==# expand('~')
    return
  endif
  let l:dir = fnamemodify(s:recent_projects_file, ':h')
  if !isdirectory(l:dir)
    silent! call mkdir(l:dir, 'p', 0700)
  endif
  let l:lines = filereadable(s:recent_projects_file) ? readfile(s:recent_projects_file) : []
  call filter(l:lines, '!empty(v:val) && v:val !=# l:root')
  call insert(l:lines, l:root, 0)
  silent! call writefile(l:lines[:49], s:recent_projects_file)
endfunction

augroup vim_recent_projects
  autocmd!
  autocmd VimEnter,BufEnter * call s:record_recent_project()
augroup END

function! s:switch_project_sink(line) abort
  let l:parts = split(a:line, "\t")
  if empty(l:parts)
    return
  endif
  let l:dir = l:parts[0]
  if !isdirectory(l:dir)
    return
  endif
  execute 'cd' fnameescape(l:dir)
  let l:lines = filereadable(s:recent_projects_file) ? readfile(s:recent_projects_file) : []
  call filter(l:lines, '!empty(v:val) && v:val !=# l:dir')
  call insert(l:lines, l:dir, 0)
  silent! call writefile(l:lines[:49], s:recent_projects_file)
  " 若左侧开了 fern 文件树，同步切到新项目根
  for l:w in range(1, winnr('$'))
    if getbufvar(winbufnr(l:w), '&filetype') ==# 'fern'
      silent! execute 'Fern . -drawer'
      wincmd p
      break
    endif
  endfor
  echomsg '📂 已切换项目: ' . l:dir
  Files
endfunction

function! s:switch_project() abort
  let l:script = expand('~/.vim/scripts/ask_ai.py')
  if !executable('python3') || !filereadable(l:script)
    echohl WarningMsg | echom '未找到 python3 或 ~/.vim/scripts/ask_ai.py' | echohl None
    return
  endif
  let l:src = printf('python3 %s --list-projects %s %s',
        \ shellescape(l:script),
        \ shellescape(s:recent_projects_file),
        \ shellescape(s:current_search_root()))
  let l:preview = 'git -C {1} status -sb 2>/dev/null && echo "" && git -C {1} log --oneline --decorate --color=always -n 10 2>/dev/null || ls -la {1}'
  let l:spec = {
    \ 'source': l:src,
    \ 'sink': function('s:switch_project_sink'),
    \ 'options': [
    \   '--ansi',
    \   '-d', "\t",
    \   '--with-nth', '2..',
    \   '--tiebreak=index',
    \   '--prompt', '切换项目 (Enter 切目录并找文件)> ',
    \   '--preview', l:preview,
    \   '--preview-window', 'right,50%,<70(up,40%)',
    \ ],
    \ }
  call fzf#run(fzf#wrap('switch_project', l:spec, 0))
endfunction

nnoremap <silent> <leader>ff :Files<CR>
nnoremap <silent> <leader>fp :call <SID>switch_project()<CR>
nnoremap <silent> <leader>fg :call <SID>rg_project()<CR>
vnoremap <silent> <leader>fg :<C-u>call <SID>rg_visual()<CR>
nnoremap <silent> <leader>fb :Buffers<CR>
nnoremap <silent> <leader>fh :History<CR>
nnoremap <silent> <leader>fl :Lines<CR>
nnoremap <silent> <leader>ft :BTags<CR>
nnoremap <silent> <leader>fT :Tags<CR>
nnoremap <silent> <leader>fw :Windows<CR>

" 用 ripgrep 作为 :grep 后端
set grepprg=rg\ --vimgrep\ --smart-case\ --hidden\ --glob\ !.git/*
set grepformat=%f:%l:%c:%m

" ============================================================
"  gutentags —— 自动生成/更新 ctags
" ============================================================
let g:gutentags_cache_dir = expand('~/.cache/gutentags')
let g:gutentags_generate_on_new = 1
let g:gutentags_generate_on_missing = 1
let g:gutentags_generate_on_write = 1
let g:gutentags_ctags_extra_args = ['--extras=+q', '--fields=+niazS']
let g:gutentags_ctags_exclude = [
  \ '*.min.*', '*_test.go',
  \ 'node_modules', 'vendor', 'target', 'build', 'out', 'dist',
  \ '.git', '.idea', '.gradle', '*.log', '*.lock',
  \ ]

" ============================================================
"  tagbar —— 侧边栏符号大纲
" ============================================================
let g:tagbar_width = 35
let g:tagbar_autofocus = 1
let g:tagbar_sort = 0
nnoremap <silent> <F8> :TagbarToggle<CR>

" ============================================================
"  fern.vim —— 左侧文件树
" ============================================================
let g:fern#drawer_width = 30
let g:fern#default_hidden = 0

" F9 开关文件树（以当前工作目录为根）
nnoremap <silent> <F9> :Fern . -drawer -toggle<CR>
" 在当前文件所在目录打开文件树，并定位/展开到当前文件
nnoremap <silent> <leader>e :Fern %:h -drawer -reveal=%<CR>

" ============================================================
"  vim-sneak —— 两键跳到屏幕任意位置
" ============================================================
let g:sneak#label = 1

" ============================================================
"  Git 阅读与追溯 (vim-gitgutter + FZF 文件提交历史 + 浮窗 Git Blame)
" ============================================================
let g:gitgutter_map_keys = 0
nmap ]c <Plug>(GitGutterNextHunk)
nmap [c <Plug>(GitGutterPrevHunk)
nmap <leader>hp <Plug>(GitGutterPreviewHunk)
nmap <leader>hu <Plug>(GitGutterUndoHunk)
nmap <leader>hs <Plug>(GitGutterStageHunk)

function! s:git_open_commit(root, file_rel, line) abort
  let l:hash = matchstr(a:line, '^\S\+')
  if empty(l:hash)
    return
  endif
  let l:state = {'out': [], 'done': 0}
  call job_start(['git', '-C', a:root, 'show', '--stat', '-p', l:hash, '--', a:file_rel], {
    \ 'in_io': 'null',
    \ 'err_io': 'null',
    \ 'out_cb': {ch, msg -> add(l:state.out, msg)},
    \ 'close_cb': {ch -> s:git_render_commit_split(l:hash, a:file_rel, l:state)},
    \ })
endfunction

function! s:git_render_commit_split(hash, file_rel, state) abort
  if a:state.done
    return
  endif
  let a:state.done = 1
  botright new
  setlocal buftype=nofile bufhidden=wipe noswapfile filetype=git
  silent! execute 'file git://' . a:hash . '/' . fnameescape(fnamemodify(a:file_rel, ':t'))
  call setline(1, empty(a:state.out) ? ['(无改动内容)'] : a:state.out)
  setlocal nomodifiable readonly
  nnoremap <buffer> <silent> q :close<CR>
endfunction

function! s:git_file_commits() abort
  let l:full = expand('%:p')
  if empty(l:full) || !filereadable(l:full)
    echohl WarningMsg | echom '当前窗口不是已保存的文件' | echohl None
    return
  endif
  let l:root = s:project_root(l:full)
  if !isdirectory(l:root . '/.git') && !filereadable(l:root . '/.git')
    echohl WarningMsg | echom '当前文件不在 Git 仓库中' | echohl None
    return
  endif
  let l:rel = stridx(l:full, l:root . '/') == 0 ? strpart(l:full, len(l:root) + 1) : l:full
  let l:src = printf('git -C %s log --follow --color=always --date=short --format="%%C(yellow)%%h%%C(reset) %%C(green)%%ad%%C(reset) %%C(cyan)%%an%%C(reset): %%s" -- %s',
        \ shellescape(l:root), shellescape(l:rel))
  let l:prev = printf('git -C %s show --color=always {1} -- %s',
        \ shellescape(l:root), shellescape(l:rel))
  let l:spec = {
    \ 'source': l:src,
    \ 'sink': {line -> s:git_open_commit(l:root, l:rel, line)},
    \ 'options': [
    \   '--ansi',
    \   '--tiebreak=index',
    \   '--prompt', printf('文件历史 [%s]> ', fnamemodify(l:rel, ':t')),
    \   '--preview', l:prev,
    \   '--preview-window', 'right,60%,<70(up,50%)',
    \ ],
    \ }
  call fzf#run(fzf#wrap('git_bcommits', l:spec, 0))
endfunction

function! s:git_blame_render(root, state) abort
  if a:state.done
    return
  endif
  let a:state.done = 1
  if empty(a:state.out)
    echohl WarningMsg | echom '未获取到该行的 Git Blame 信息（可能是新文件）' | echohl None
    return
  endif
  let l:first = a:state.out[0]
  let l:hash = matchstr(l:first, '^\x\+')
  if empty(l:hash) || l:hash =~# '^0\+$'
    call popup_atcursor([' ✨ 尚未提交的本地修改 (Uncommitted Changes) '], {
      \ 'border': [],
      \ 'padding': [0, 1, 0, 1],
      \ 'moved': 'any',
      \ 'mapping': 0,
      \ })
    return
  endif
  let l:log_state = {'out': [], 'done': 0}
  call job_start([
        \ 'git', '-C', a:root, 'show', '-s',
        \ '--date=format:%Y-%m-%d %H:%M:%S',
        \ '--format=Commit: %h (%ad, %ar)%nAuthor: %an <%ae>%n%n%B',
        \ l:hash
        \ ], {
        \ 'in_io': 'null',
        \ 'err_io': 'null',
        \ 'out_cb': {ch, msg -> add(l:log_state.out, msg)},
        \ 'close_cb': {ch -> s:git_blame_show_popup(l:log_state)},
        \ })
endfunction

function! s:git_blame_popup_filter(winid, key) abort
  if a:key ==# 'q' || a:key ==# "\<Esc>"
    call popup_close(a:winid)
    return 1
  endif
  return 0
endfunction

function! s:git_blame_show_popup(log_state) abort
  if a:log_state.done
    return
  endif
  let a:log_state.done = 1
  let l:lines = copy(a:log_state.out)
  while !empty(l:lines) && empty(trim(l:lines[-1]))
    call remove(l:lines, -1)
  endwhile
  if empty(l:lines)
    return
  endif
  call add(l:lines, '')
  call add(l:lines, '[移动光标或按 q / Esc 关闭]')
  call popup_atcursor(l:lines, {
    \ 'border': [],
    \ 'padding': [0, 1, 0, 1],
    \ 'maxwidth': 78,
    \ 'maxheight': 20,
    \ 'wrap': 1,
    \ 'moved': 'any',
    \ 'filter': function('s:git_blame_popup_filter'),
    \ })
endfunction

function! s:git_blame_line() abort
  let l:full = expand('%:p')
  if empty(l:full) || !filereadable(l:full)
    echohl WarningMsg | echom '当前窗口不是已保存的文件' | echohl None
    return
  endif
  let l:root = s:project_root(l:full)
  let l:lnum = line('.')
  let l:state = {'out': [], 'done': 0}
  call job_start(['git', '-C', l:root, 'blame', '-L', l:lnum . ',' . l:lnum, '--porcelain', '--', l:full], {
    \ 'in_io': 'null',
    \ 'err_io': 'null',
    \ 'out_cb': {ch, msg -> add(l:state.out, msg)},
    \ 'close_cb': {ch -> s:git_blame_render(l:root, l:state)},
    \ })
endfunction

nnoremap <silent> <leader>gc :call <SID>git_file_commits()<CR>
nnoremap <silent> <leader>gb :call <SID>git_blame_line()<CR>

" ============================================================
"  杂项
" ============================================================
" 快速保存
nnoremap <leader>w :w<CR>
nnoremap <leader>q :q<CR>

" 打开 quickfix（grep / 引用结果都进这里）
nnoremap <leader>co :copen<CR>
nnoremap <leader>cc :cclose<CR>

" 个人快捷键速查帮助与 README 查看命令
function! s:open_readme() abort
  for l:cand in ['~/.vim/README.md']
    let l:path = expand(l:cand)
    if filereadable(l:path)
      execute 'botright split' fnameescape(l:path)
      setlocal readonly nomodifiable buftype=nowrite bufhidden=wipe
      nnoremap <buffer> <silent> q :close<CR>
      return
    endif
  endfor
  execute 'help myvim'
endfunction

command! Keys   help myvim
command! MyHelp help myvim
command! Readme call <SID>open_readme()
nnoremap <silent> <leader>? :help myvim<CR>

augroup vim_help_q_close
  autocmd!
  autocmd FileType help nnoremap <buffer> <silent> q :close<CR>
augroup END

" ============================================================
"  AI Agent 代码分析与追问 (agy / claude / codex / Herdr 窗口)
" ============================================================
let g:herdr_ai_default_agent = 'agy'
nnoremap <silent> <leader>ai :call herdr_ai#ask('n', 1)<CR>
xnoremap <silent> <leader>ai :<C-u>call herdr_ai#ask('v', 1)<CR>
nnoremap <silent> <leader>aa :call herdr_ai#ask('n', 0)<CR>
xnoremap <silent> <leader>aa :<C-u>call herdr_ai#ask('v', 0)<CR>
nnoremap <silent> <leader>aq :call herdr_ai#ask_question('n', 0)<CR>
xnoremap <silent> <leader>aq :<C-u>call herdr_ai#ask_question('v', 0)<CR>
nnoremap <silent> <leader>aQ :call herdr_ai#ask_question('n', 1)<CR>
xnoremap <silent> <leader>aQ :<C-u>call herdr_ai#ask_question('v', 1)<CR>
nnoremap <silent> <leader>as :call herdr_ai#send_to_agent('n', 0)<CR>
xnoremap <silent> <leader>as :<C-u>call herdr_ai#send_to_agent('v', 0)<CR>
nnoremap <silent> <leader>aS :call herdr_ai#send_to_agent('n', 1)<CR>
xnoremap <silent> <leader>aS :<C-u>call herdr_ai#send_to_agent('v', 1)<CR>
nnoremap <silent> <leader>ah :call herdr_ai#browse_history()<CR>
command! -nargs=* AIAsk call herdr_ai#ask_question('n', 0, <q-args>)
command! AIHistory call herdr_ai#browse_history()

" 终端里用鼠标滚动
set ttymouse=sgr

" 终端标题栏显示当前打开文件的完整绝对路径（供 Herdr / herdr-app 面板顶部显示）
set title
function! s:update_vim_title() abort
  if &buftype ==# '' && &filetype !~# '^\(fern\|tagbar\|qf\)$'
    let l:full = expand('%:p')
    if !empty(l:full)
      let &titlestring = l:full
      if exists('$HERDR_PANE_ID') && !empty($HERDR_PANE_ID) && l:full !=# get(g:, '_herdr_last_title', '')
        let g:_herdr_last_title = l:full
        if exists('*job_start')
          call job_start(['herdr', 'pane', 'rename', $HERDR_PANE_ID, 'Vim · ' . l:full], {'stoponexit': ''})
        endif
      endif
    endif
  endif
endfunction
function! s:clear_herdr_vim_title() abort
  if exists('$HERDR_PANE_ID') && !empty($HERDR_PANE_ID) && exists('*job_start')
    call job_start(['herdr', 'pane', 'rename', $HERDR_PANE_ID, '--clear'], {'stoponexit': ''})
  endif
endfunction
augroup vim_title_fullpath
  autocmd!
  autocmd VimEnter,BufEnter,BufWinEnter,BufFilePost,DirChanged * call s:update_vim_title()
  autocmd VimLeavePre * call s:clear_herdr_vim_title()
augroup END

" ============================================================
"  终端右键浮动菜单 & 系统剪贴板同步（支持本地 Wayland/X11/macOS 与 SSH OSC52）
" ============================================================
function! s:sys_copy_osc52_finish(state) abort
  if a:state.done
    return
  endif
  let a:state.done = 1
  let l:b64 = substitute(join(a:state.chunks, ''), '[\r\n]\+', '', 'g')
  if !empty(l:b64)
    let l:osc = "\x1b]52;c;" . l:b64 . "\x07"
    if !empty($TMUX)
      let l:osc = "\x1bPtmux;\x1b" . l:osc . "\x1b\\"
    endif
    call echoraw(l:osc)
  endif
endfunction

function! s:sys_copy(text) abort
  if empty(a:text)
    return
  endif
  if has('clipboard')
    silent! call setreg('+', a:text)
    silent! call setreg('*', a:text)
  endif
  " 1) OSC 52：本地终端与 SSH 远程终端均可直接写入宿主机系统剪贴板
  "    优先使用 job_start() 异步编码，避免 system() 触发终端模式重置
  if exists('*echoraw') && strlen(a:text) <= 100000 && executable('base64')
    if exists('*job_start')
      let l:b64_state = {'chunks': [], 'done': 0}
      let l:b64_job = job_start(['base64'], {
        \ 'in_io': 'pipe',
        \ 'err_io': 'null',
        \ 'out_mode': 'raw',
        \ 'out_cb': {ch, msg -> add(l:b64_state.chunks, msg)},
        \ 'close_cb': {ch -> s:sys_copy_osc52_finish(l:b64_state)},
        \ })
      if job_status(l:b64_job) ==# 'run'
        let l:b64_ch = job_getchannel(l:b64_job)
        call ch_sendraw(l:b64_ch, a:text)
        call ch_close_in(l:b64_ch)
      endif
    else
      let l:b64 = substitute(system('base64', a:text), '[\r\n]\+', '', 'g')
      if v:shell_error == 0 && !empty(l:b64)
        let l:osc = "\x1b]52;c;" . l:b64 . "\x07"
        if !empty($TMUX)
          let l:osc = "\x1bPtmux;\x1b" . l:osc . "\x1b\\"
        endif
        call echoraw(l:osc)
      endif
    endif
  endif
  " 2) 本地桌面剪贴板工具同步（异步管道发送，避免 wl-copy / xclip 阻塞 Vim）
  let l:cmd = []
  if !empty($WAYLAND_DISPLAY) && executable('wl-copy')
    let l:cmd = ['wl-copy']
  elseif !empty($DISPLAY) && executable('xclip')
    let l:cmd = ['xclip', '-selection', 'clipboard', '-in']
  elseif !empty($DISPLAY) && executable('xsel')
    let l:cmd = ['xsel', '--clipboard', '--input']
  elseif executable('pbcopy')
    let l:cmd = ['pbcopy']
  endif
  if !empty(l:cmd) && exists('*job_start')
    let l:job = job_start(l:cmd, {'in_io': 'pipe', 'out_io': 'null', 'err_io': 'null', 'stoponexit': ''})
    if job_status(l:job) ==# 'run'
      let l:ch = job_getchannel(l:job)
      call ch_sendraw(l:ch, a:text)
      call ch_close_in(l:ch)
    endif
  endif
endfunction

function! s:sys_read_clipboard() abort
  if has('clipboard') && !empty(@+)
    return [@+, getregtype('+')]
  endif
  let l:out = ''
  if !empty($WAYLAND_DISPLAY) && executable('wl-paste')
    let l:out = system('wl-paste --no-newline 2>/dev/null')
    if v:shell_error == 0 && !empty(l:out)
      return [substitute(l:out, "\r\n", "\n", 'g'), 'v']
    endif
  elseif !empty($DISPLAY) && executable('xclip')
    let l:out = system('xclip -selection clipboard -o 2>/dev/null')
    if v:shell_error == 0 && !empty(l:out)
      return [substitute(l:out, "\r\n", "\n", 'g'), 'v']
    endif
  elseif !empty($DISPLAY) && executable('xsel')
    let l:out = system('xsel --clipboard --output 2>/dev/null')
    if v:shell_error == 0 && !empty(l:out)
      return [substitute(l:out, "\r\n", "\n", 'g'), 'v']
    endif
  elseif executable('pbpaste')
    let l:out = system('pbpaste 2>/dev/null')
    if v:shell_error == 0 && !empty(l:out)
      return [substitute(l:out, "\r\n", "\n", 'g'), 'v']
    endif
  endif
  return [getreg('"'), getregtype('"')]
endfunction

function! s:ctx_copy_visual() abort
  let l:save_reg = getreg('z')
  let l:save_type = getregtype('z')
  try
    if mode() =~# "[vV\<C-v>]"
      silent normal! "zy
    else
      silent normal! gv"zy
    endif
    let l:text = getreg('z')
    let l:rtype = getregtype('z')
  finally
    call setreg('z', l:save_reg, l:save_type)
  endtry
  call s:sys_copy(l:text)
  call setreg('"', l:text, l:rtype)
  echo '已复制选中内容 (' . strchars(l:text) . ' 字符)'
endfunction

function! s:ctx_cut_visual() abort
  if !&modifiable || &readonly
    call s:ctx_copy_visual()
    return
  endif
  let l:save_reg = getreg('z')
  let l:save_type = getregtype('z')
  try
    if mode() =~# "[vV\<C-v>]"
      silent normal! "zd
    else
      silent normal! gv"zd
    endif
    let l:text = getreg('z')
    let l:rtype = getregtype('z')
  finally
    call setreg('z', l:save_reg, l:save_type)
  endtry
  call s:sys_copy(l:text)
  call setreg('"', l:text, l:rtype)
  echo '已剪切选中内容 (' . strchars(l:text) . ' 字符)'
endfunction

function! s:sys_read_clipboard_finish(state, cb) abort
  if a:state.done
    return
  endif
  let a:state.done = 1
  let l:out = substitute(join(a:state.chunks, ''), "\r\n", "\n", 'g')
  if !empty(l:out)
    call a:cb(l:out, 'v')
  else
    call a:cb(getreg('"'), getregtype('"'))
  endif
endfunction

function! s:sys_read_clipboard_async(cb) abort
  if has('clipboard') && !empty(@+)
    call a:cb(@+, getregtype('+'))
    return
  endif
  let l:cmd = []
  if !empty($WAYLAND_DISPLAY) && executable('wl-paste')
    let l:cmd = ['wl-paste', '--no-newline']
  elseif !empty($DISPLAY) && executable('xclip')
    let l:cmd = ['xclip', '-selection', 'clipboard', '-o']
  elseif !empty($DISPLAY) && executable('xsel')
    let l:cmd = ['xsel', '--clipboard', '--output']
  elseif executable('pbpaste')
    let l:cmd = ['pbpaste']
  endif
  if !empty(l:cmd) && exists('*job_start')
    let l:state = {'chunks': [], 'done': 0}
    let l:job = job_start(l:cmd, {
      \ 'in_io': 'null',
      \ 'err_io': 'null',
      \ 'out_mode': 'raw',
      \ 'out_cb': {ch, msg -> add(l:state.chunks, msg)},
      \ 'close_cb': {ch -> s:sys_read_clipboard_finish(l:state, a:cb)},
      \ })
    if job_status(l:job) !=# 'fail'
      return
    endif
  endif
  let [l:text, l:rtype] = s:sys_read_clipboard()
  call a:cb(l:text, l:rtype)
endfunction

function! s:ctx_insert_at(lnum, col, text) abort
  let l:cur = getline(a:lnum)
  let l:before = a:col > 1 ? l:cur[:a:col - 2] : ''
  let l:after = l:cur[a:col - 1:]
  let l:parts = split(a:text, "\n", 1)
  if len(l:parts) == 1
    call setline(a:lnum, l:before . l:parts[0] . l:after)
    call cursor(a:lnum, strlen(l:before . l:parts[0]) + 1)
  else
    call setline(a:lnum, l:before . l:parts[0])
    call append(a:lnum, l:parts[1:-2] + [l:parts[-1] . l:after])
    call cursor(a:lnum + len(l:parts) - 1, strlen(l:parts[-1]) + 1)
  endif
endfunction

function! s:ctx_paste_apply(mode, text, rtype) abort
  if !&modifiable || &readonly
    echohl WarningMsg | echo '当前窗口为只读，无法粘贴' | echohl None
    return
  endif
  if empty(a:text)
    echohl WarningMsg | echo '剪贴板为空（远程终端粘贴外部内容可直接按 Ctrl+Shift+V / Cmd+V）' | echohl None
    return
  endif
  if a:mode ==# 'i'
    call s:ctx_insert_at(line('.'), col('.'), a:text)
    return
  endif
  if a:mode ==# 'v' && mode() ==# 'v'
    let l:p1 = getpos('v')
    let l:p2 = getpos('.')
    if l:p1[1] < l:p2[1] || (l:p1[1] == l:p2[1] && l:p1[2] <= l:p2[2])
      let [l:sl, l:sc] = [l:p1[1], l:p1[2]]
    else
      let [l:sl, l:sc] = [l:p2[1], l:p2[2]]
    endif
    silent normal! "_d
    call s:ctx_insert_at(l:sl, l:sc, a:text)
    return
  endif
  let l:save_reg = getreg('z')
  let l:save_type = getregtype('z')
  try
    call setreg('z', a:text, a:rtype)
    if a:mode ==# 'v'
      silent normal! gv"zp
    else
      silent normal! "zp
    endif
  finally
    call setreg('z', l:save_reg, l:save_type)
  endtry
endfunction

function! s:ctx_paste(mode) abort
  if !&modifiable || &readonly
    echohl WarningMsg | echo '当前窗口为只读，无法粘贴' | echohl None
    return
  endif
  call s:sys_read_clipboard_async({text, rtype -> s:ctx_paste_apply(a:mode, text, rtype)})
endfunction

function! s:ctx_copy_word() abort
  let l:word = expand('<cword>')
  if empty(l:word)
    call s:ctx_copy_line()
    return
  endif
  call s:sys_copy(l:word)
  call setreg('"', l:word, 'v')
  echo '已复制: ' . l:word
endfunction

function! s:ctx_copy_line() abort
  let l:line = getline('.')
  call s:sys_copy(l:line)
  call setreg('"', l:line . "\n", 'V')
  echo '已复制当前行 (第 ' . line('.') . ' 行)'
endfunction

function! s:ctx_copy_path() abort
  let l:path = expand('%:p')
  let l:target = empty(l:path) ? getcwd() : (l:path . ':' . line('.'))
  call s:sys_copy(l:target)
  call setreg('"', l:target, 'v')
  echo '已复制路径: ' . l:target
endfunction

function! s:ctx_goto_def() abort
  if !empty(maparg('gd', 'n'))
    execute "normal gd"
  else
    silent! execute "normal! \<C-]>"
  endif
endfunction

function! s:ctx_rg_cword() abort
  call HerdrSearchInDir(s:current_search_root(), expand('<cword>'))
endfunction

" 普通 y 复制时自动同步到系统剪贴板（不影响 d/c/x 删除操作）
augroup vim_yank_sysclip
  autocmd!
  autocmd TextYankPost * if v:event.operator ==# 'y' && (empty(v:event.regname) || v:event.regname =~# '^[+*]$') | call s:sys_copy(join(v:event.regcontents, "\n")) | endif
augroup END

" 右键弹出浮动菜单（定位光标到点击处；Visual 模式下任意位置右键均保留当前选区）
set mousemodel=popup_setpos
if has('menu')
  silent! aunmenu PopUp

  vnoremenu <silent> 10.10  PopUp.复制选中内容\ \ (Copy)      :<C-u>call <SID>ctx_copy_visual()<CR>
  vnoremenu <silent> 10.20  PopUp.剪切选中内容\ \ (Cut)       :<C-u>call <SID>ctx_cut_visual()<CR>
  vnoremenu <silent> 10.30  PopUp.粘贴替换选中\ \ (Paste)     :<C-u>call <SID>ctx_paste('v')<CR>
  vnoremenu          10.40  PopUp.-sep1-                     :
  vnoremenu <silent> 10.50  PopUp.全文搜索选中\ \ (Space+fg)  :<C-u>call <SID>rg_visual()<CR>
  vnoremenu <silent> 10.55  PopUp.发送到\ Agent\ (Space+as)    :<C-u>call herdr_ai#send_to_agent('v', 0)<CR>
  vnoremenu <silent> 10.60  PopUp.AI\ 分析选中\ \ \ (Space+aa) :<C-u>call herdr_ai#ask('v', 0)<CR>
  vnoremenu <silent> 10.70  PopUp.AI\ 选模型分析\ (Space+ai)  :<C-u>call herdr_ai#ask('v', 1)<CR>

  nnoremenu <silent> 10.10  PopUp.复制当前词\ \ \ \ (yiw)       :call <SID>ctx_copy_word()<CR>
  nnoremenu <silent> 10.20  PopUp.复制当前行\ \ \ \ (yy)        :call <SID>ctx_copy_line()<CR>
  nnoremenu <silent> 10.30  PopUp.粘贴\ \ \ \ \ \ \ \ \ \ (Paste)     :call <SID>ctx_paste('n')<CR>
  nnoremenu          10.40  PopUp.-sep1-                       :
  nnoremenu <silent> 10.50  PopUp.转到定义\ \ \ \ \ \ (gd)       :call <SID>ctx_goto_def()<CR>
  nnoremenu <silent> 10.60  PopUp.查找所有引用\ \ (gr)          :call <SID>lsp_fzf_location('references', 'References (调用路径)')<CR>
  nnoremenu <silent> 10.70  PopUp.查找接口实现\ \ (gi)          :call <SID>lsp_fzf_location('implementation', 'Implementations (具体实现)')<CR>
  nnoremenu <silent> 10.80  PopUp.全文搜索当前词\ (Space+fg)    :call <SID>ctx_rg_cword()<CR>
  nnoremenu          10.90  PopUp.-sep2-                       :
  nnoremenu <silent> 10.95  PopUp.发送到\ Agent\ \ \ (Space+as)   :call herdr_ai#send_to_agent('n', 0)<CR>
  nnoremenu <silent> 10.100 PopUp.AI\ 分析方法\ \ \ (Space+aa)   :call herdr_ai#ask('n', 0)<CR>
  nnoremenu <silent> 10.105 PopUp.Git\ Blame\ 当前行\ (Space+gb)  :call <SID>git_blame_line()<CR>
  nnoremenu <silent> 10.110 PopUp.复制路径与行号\ (Path)        :call <SID>ctx_copy_path()<CR>

  inoremenu <silent> 10.10  PopUp.粘贴\ \ \ \ \ \ \ \ (Paste)     <C-o>:call <SID>ctx_paste('i')<CR>
  inoremenu <silent> 10.20  PopUp.复制当前词\ \ (Copy\ Word)  <C-o>:call <SID>ctx_copy_word()<CR>
  inoremenu <silent> 10.30  PopUp.复制当前行\ \ (Copy\ Line)  <C-o>:call <SID>ctx_copy_line()<CR>

  xnoremap <silent> <RightMouse> <Cmd>popup! PopUp<CR>
endif

" 终端 Vim 9.1 中，Insert 及 -- (insert) VISUAL -- 模式下点击 :popup PopUp 菜单项会以
" Normal 模式执行 :emenu，导致 E335: Menu not defined for Normal mode。此处统一改用原生
" popup_menu() 响应 Insert 与 Visual（含 Insert-Visual）右键菜单，支持鼠标点击与键盘选择。
if !has('gui_running') && exists('*popup_menu')
  function! s:ctx_popup_filter(winid, key) abort
    if a:key ==# "\<LeftMouse>"
      let l:pos = getmousepos()
      let l:p = popup_getpos(a:winid)
      let l:row = l:pos.screenrow - l:p.core_line + 1
      if l:pos.screencol >= l:p.col && l:pos.screencol < l:p.col + l:p.width
            \ && l:row >= 1 && l:row <= l:p.core_height
        call popup_close(a:winid, l:row)
      else
        call popup_close(a:winid, -1)
      endif
      return 1
    elseif a:key ==# "\<RightMouse>"
      call popup_close(a:winid, -1)
      return 1
    endif
    return popup_filter_menu(a:winid, a:key)
  endfunction

  function! s:ctx_popup_opts(cb) abort
    let l:pos = getmousepos()
    let l:opts = {
      \ 'pos': 'topleft',
      \ 'callback': a:cb,
      \ 'filter': function('s:ctx_popup_filter'),
      \ 'border': [],
      \ 'padding': [0, 1, 0, 1],
      \ 'highlight': 'Pmenu',
      \ 'moved': 'any',
      \ }
    if get(l:pos, 'screenrow', 0) > 0
      let l:opts['line'] = l:pos.screenrow
      let l:opts['col'] = l:pos.screencol
    else
      let l:opts['line'] = 'cursor+1'
      let l:opts['col'] = 'cursor'
    endif
    return l:opts
  endfunction

  function! s:ctx_insert_popup_cb(id, result) abort
    if a:result == 1
      call s:ctx_paste('i')
    elseif a:result == 2
      call s:ctx_copy_word()
    elseif a:result == 3
      call s:ctx_copy_line()
    endif
  endfunction

  function! s:ctx_insert_popup() abort
    call popup_menu([
      \ '粘贴        (Paste)',
      \ '复制当前词  (Copy Word)',
      \ '复制当前行  (Copy Line)',
      \ ], s:ctx_popup_opts(function('s:ctx_insert_popup_cb')))
  endfunction

  function! s:ctx_visual_popup_cb(id, result) abort
    if a:result <= 0 || a:result == 4
      return
    endif
    if a:result == 1
      call s:ctx_copy_visual()
    elseif a:result == 2
      call s:ctx_cut_visual()
    elseif a:result == 3
      call s:ctx_paste('v')
    elseif a:result == 5
      if mode() =~# "[vV\<C-v>]"
        silent execute "normal! \<Esc>"
      endif
      call s:rg_visual()
    elseif a:result == 6
      call herdr_ai#send_to_agent('v', 0)
    elseif a:result == 7
      if mode() =~# "[vV\<C-v>]"
        silent execute "normal! \<Esc>"
      endif
      call herdr_ai#ask('v', 0)
    elseif a:result == 8
      if mode() =~# "[vV\<C-v>]"
        silent execute "normal! \<Esc>"
      endif
      call herdr_ai#ask('v', 1)
    endif
  endfunction

  function! s:ctx_visual_popup() abort
    call popup_menu([
      \ '复制选中内容  (Copy)',
      \ '剪切选中内容  (Cut)',
      \ '粘贴替换选中  (Paste)',
      \ '──────────────────────────',
      \ '全文搜索选中  (Space+fg)',
      \ '发送到 Agent  (Space+as)',
      \ 'AI 分析选中   (Space+aa)',
      \ 'AI 选模型分析 (Space+ai)',
      \ ], s:ctx_popup_opts(function('s:ctx_visual_popup_cb')))
  endfunction

  inoremap <silent> <RightMouse> <Cmd>call <SID>ctx_insert_popup()<CR>
  vnoremap <silent> <RightMouse> <Cmd>call <SID>ctx_visual_popup()<CR>
endif
noremap  <RightDrag> <Nop>
noremap! <RightDrag> <Nop>
