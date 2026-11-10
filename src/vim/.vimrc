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
set number relativenumber
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

" 关闭备份/交换文件带来的噪音
set nobackup nowritebackup
set noswapfile

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

" 找项目根：从当前文件向上找常见的构建/版本控制标记
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
    let l:found = findfile(l:marker, l:dir . ';')   " .git 在 worktree/submodule 中可能是文件
    if !empty(l:found)
      return fnamemodify(l:found, ':h')
    endif
  endfor
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

nnoremap <silent> <leader>ff :Files<CR>
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

" 终端里用鼠标滚动
set ttymouse=sgr

" 终端标题栏显示当前打开文件的完整绝对路径（供 Herdr 面板顶部显示）
set title
function! s:update_vim_title() abort
  if &buftype ==# '' && &filetype !~# '^\(fern\|tagbar\|qf\)$'
    let l:full = expand('%:p')
    if !empty(l:full)
      let &titlestring = l:full
    endif
  endif
endfunction
augroup vim_title_fullpath
  autocmd!
  autocmd VimEnter,BufEnter,BufWinEnter,BufFilePost,DirChanged * call s:update_vim_title()
augroup END

" 禁用鼠标右键：默认在 Normal/Insert 模式下右键会开始/扩展 Visual 选区
nnoremap <RightMouse>   <Nop>
nnoremap <RightDrag>    <Nop>
nnoremap <RightRelease> <Nop>
vnoremap <RightMouse>   <Nop>
vnoremap <RightDrag>    <Nop>
vnoremap <RightRelease> <Nop>
noremap! <RightMouse>   <Nop>
noremap! <RightDrag>    <Nop>
noremap! <RightRelease> <Nop>
