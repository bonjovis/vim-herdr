# Vim 开发环境使用说明

> 适用环境：Fedora / 系统自带的终端版 **Vim 9.1**（非 Neovim）
> 主配置文件：`~/.vimrc`（带中文注释，可直接修改）
> 目标：在 Go / Java / TypeScript / JavaScript / PHP 项目中实现代码跳转、引用查找、符号搜索、文件与全文搜索

---

## 一、方案概览

采用 **vim-lsp + vim-lsp-settings** 作为 LSP 客户端，配合 fzf、fern、ctags、tagbar：

| 能力 | 实现 |
|---|---|
| 转到定义 / 引用 / 实现 / 类型定义 | vim-lsp + 各语言 LSP server |
| 补全（`<C-x><C-o>`） | vim-lsp（omni completion） |
| 重命名 / 代码操作 / 格式化 | vim-lsp |
| 文件模糊搜索、全文搜索 | fzf.vim + ripgrep |
| 文件树浏览 / 文件管理 | fern.vim |
| 函数/类大纲 | tagbar + universal-ctags |
| tags 自动生成 | vim-gutentags |
| 文件内两键跳转 | vim-sneak |

---

## 二、已安装的插件与工具

### 2.1 Vim 插件（vim-plug 管理）

| 插件 | 当前 commit | 用途 |
|---|---|---|
| `prabirshrestha/vim-lsp` | `977e704` | LSP 客户端（定义、引用、补全、重命名等） |
| `mattn/vim-lsp-settings` | `83f6480` | 按文件类型自动配置/安装 LSP server |
| `junegunn/fzf` | `26ff936` | fzf 的 Vim 核心支持（`fzf#run` 等） |
| `junegunn/fzf.vim` | `023de3c` | `:Files` `:Rg` `:Buffers` `:BTags` 等命令 |
| `ludovicchabant/vim-gutentags` | `aa47c5e` | 自动生成并增量更新 ctags |
| `preservim/tagbar` | `07cb824` | 侧边栏符号大纲 |
| `lambdalisue/fern.vim` | `eaf8395` | 左侧文件树 / 文件管理 |
| `justinmk/vim-sneak` | `feea86a` | 两键跳转到屏幕任意位置 |

### 2.2 外部工具与 LSP server

| 组件 | 版本 | 安装位置 | 说明 |
|---|---|---|---|
| vim-plug | — | `~/.vim/autoload/plug.vim` | 插件管理器 |
| Universal Ctags | 6.0.0 | `/usr/bin/ctags` | tagbar / gutentags 依赖，支持 Go、Java、PHP 等 |
| ripgrep | 14.1.1 | `/usr/bin/rg` | 全文搜索，`:grep` 与 fzf 默认后端 |
| fzf | 0.74.5 | `~/.fzf/bin/fzf`（软链到 `~/.local/bin/fzf`） | 模糊查找 |
| gopls | v0.24.0 | `~/.local/bin/gopls` | Go LSP |
| Eclipse JDTLS | **1.58.0（固定版本）** | `~/.local/share/vim-lsp-settings/servers/eclipse-jdt-ls/` | Java LSP，见下方注意事项 |
| typescript-language-server | 5.3.0（typescript 6.0.3） | 同目录 `servers/typescript-language-server/` | TS / JS LSP |
| intelephense | 1.18.5 | 同目录 `servers/intelephense/` | PHP LSP |

> **Java 特别注意**：JDTLS 官方 latest 快照已经要求 **Java 25**，本机只有 JDK 21，因此固定安装 1.58.0，
> 并在 `~/.vimrc` 中把 `JAVA_HOME` / `PATH` 指向 `/usr/lib/jvm/java-21`。
> **不要**对 `eclipse-jdt-ls` 执行 `:LspInstallServer`（会重新下载 latest 导致无法启动）。
> 以后如果安装了 JDK 25，可以删除该目录后重新安装最新版。

---

## 三、目录结构

```
~/.vimrc                                  # 主配置（所有快捷键都在这里）
~/.vim/autoload/plug.vim                  # vim-plug
~/.vim/plugged/                           # 插件本体
~/.fzf/                                   # fzf 源码 + 二进制
~/.local/bin/fzf -> ~/.fzf/bin/fzf        # 让 Vim/终端能找到 fzf
~/.local/bin/gopls                        # Go LSP
~/.local/share/vim-lsp-settings/servers/  # 各语言 LSP server
    ├── eclipse-jdt-ls/                   #   Java (1.58.0)
    ├── typescript-language-server/       #   TS / JS
    └── intelephense/                     #   PHP
~/.cache/gutentags/                       # 自动生成的 tags 缓存
```

---

## 四、快捷键速查

> Leader 键为**空格**（`<Space>`）。下表中 `<leader>` 即空格键。
> 单独按空格做右移时会有约 400ms 等待（`timeoutlen`）；觉得慢可在 `~/.vimrc` 里调小，或把 `mapleader` 换成其他键。

### 4.1 代码导航（在有 LSP server 的 buffer 中生效）

| 按键 | 功能 |
|---|---|
| `gd` | 转到定义（go to definition） |
| `gD` | 转到声明（declaration） |
| `gr` | **所有调用路径 / 引用列表（FZF 弹窗 + 右侧代码预览 + 自动标注外层调用方法名，回车直接跳转）** |
| `gi` | **接口/抽象方法的所有具体实现列表（FZF 弹窗 + 右侧代码预览，选中回车切到具体实现）** |
| `<leader>ci` | **调用层级（上游 Incoming Calls）：谁调用了当前方法（FZF 弹窗 + 预览，不支持时自动回退 `gr`）** |
| `<leader>cg` | **调用层级（下游 Outgoing Calls）：当前方法内部调用了哪些方法（FZF 弹窗 + 预览）** |
| `<leader>ct` | **多层调用树展开**：在底部 quickfix 窗口逐层向上追加调用链树（`:LspAddTreeCallHierarchyIncoming`） |
| `gy` | 转到类型定义 |
| `K` 或 `Ctrl-k` | 悬浮显示文档 / 类型信息 |
| `<leader>rn` | 重命名符号（跨文件） |
| `<leader>ca` | 代码操作（quick fix / 自动导入等） |
| `<leader>d` | 当前文件符号列表（跳到函数/类） |
| `<leader>s` | 全项目符号搜索 |
| `<leader>lf` | 格式化当前文件 |
| `<leader>pd` | 预览定义（不跳走） |
| `<leader>pr` | 预览引用 |
| `]g` / `[g` | 下一个 / 上一个错误或警告 |

补充：

- `gr` / `gi` / `<leader>ci` / `<leader>cg` 弹出的 FZF 窗口中：
  - **左侧列表**：显示 `相对路径:行号:列号: [调用方方法名] 代码行`，支持直接输入文件名或函数名模糊过滤，`↑`/`↓`（或 `Ctrl-j`/`Ctrl-k`）上下选择。
  - **右侧窗口**：实时高亮预览目标文件对应行的代码上下文（`Ctrl-/` 可开关预览）。
  - **回车跳转**：按 `Enter` 直接跳转到目标文件对应行，跳转后随时可按 **`Ctrl-o`** 原路返回（同时结果也会写入 quickfix，可按 `<leader>co` 随时重看）。
- `Ctrl-]` 也会优先走 LSP（配置了 `tagfunc`），LSP 不可用时自动回退 ctags。

### 4.2 搜索（fzf + ripgrep）

| 按键 | 功能 |
|---|---|
| `<leader>ff` | 找文件（`rg --files`，自动忽略 `.git` / `.gitignore`） |
| `<leader>fg` | 全项目全文搜索（ripgrep，按项目根 / 文件树根搜索） |
| `<leader>fb` | 已打开的 buffer 列表 |
| `<leader>fh` | 最近打开的文件历史 |
| `<leader>fl` | 当前文件内的行搜索 |
| `<leader>ft` | 当前文件的函数/符号（基于 tags） |
| `<leader>fT` | 全项目函数/符号（基于 tags） |
| `<leader>fw` | 窗口列表 |

fzf 窗口里：`Ctrl-/` 切换预览，`Enter` 打开，`Ctrl-c` / `Esc` 取消。

`<leader>fg` 是交互式搜索：按下去会弹出 fzf 窗口，接着**输入关键字**（边输入边过滤），再按 `Enter` 跳转。
搜索目录这样确定：

- 在 fern 文件树窗口里：使用文件树的根目录；
- 在普通文件里：从当前文件向上找 `go.mod`、`pom.xml`、`build.gradle`、`package.json`、`composer.json`、`.git` 等标记，作为项目根；
- 无名 buffer（直接 `vim` 启动）：使用 Vim 当前工作目录（`:pwd` 查看）。

确定后会在当前窗口执行 `:lcd` 到该根目录，所以相对路径和搜索范围都以项目根为准。
ripgrep 默认遵守 `.gitignore`，`node_modules`、`vendor`、`target` 等被忽略的目录搜不到是正常的。

`<leader>fg` 搜索到结果后可以直接跳到对应行；需要在整个项目里改关键字时：

```vim
:grep 关键字      " 使用 ripgrep 搜索，结果进入 quickfix
:copen            " 或按 <leader>co 打开列表
:cfdo %s/旧/新/g | update    " 批量替换
```

`<leader>co` 打开 quickfix，`<leader>cc` 关闭。

### 4.3 符号大纲 / tags

| 按键 / 命令 | 功能 |
|---|---|
| `F8` | 打开/关闭 tagbar 大纲 |
| `:GutentagsUpdate` | 强制重新生成当前项目的 tags（在项目文件 buffer 中可用） |
| `:GutentagsToggleEnabled` | 临时关闭/开启自动 tags 更新 |

- tags 存在 `~/.cache/gutentags/`，按项目路径命名，切换项目互不影响。
- 首次打开较大项目时会在后台生成，不会卡住编辑器。
- 已排除 `node_modules`、`vendor`、`target`、`build`、`dist`、`.git`、`.idea`、`.gradle` 等目录。

### 4.4 文件树（fern.vim）

| 按键 / 命令 | 功能 |
|---|---|
| `F9` | 打开/关闭左侧文件树（以 Vim 当前工作目录为根，宽 30 列） |
| `<leader>e` | 以当前文件所在目录为根打开文件树，并定位到当前文件 |

文件树窗口内的常用按键：

| 按键 | 功能 |
|---|---|
| `Enter` 或 `l` | 打开文件；目录则展开 |
| `Backspace` 或 `Ctrl-h` | 返回上一级目录（把父目录作为新的根） |
| `h` | 折叠当前目录 |
| `N` | 新建文件 |
| `K` | 新建目录 |
| `R` | 重命名 |
| `c` / `m` | 复制 / 移动（输入目标路径） |
| `C` / `M` / `P` | 复制 / 移动 / 粘贴（fern 内部剪贴板） |
| `y` | 把节点的完整路径复制到寄存器 |
| `D` | 移入回收站（Linux 需要 `trash-cli` 或 `gomi`，见下） |
| `!` | 显示/隐藏以 `.` 开头的隐藏文件 |
| `z` / `Z` | 放大文件树 / 恢复 30 列 |
| `F5` | 刷新目录 |
| `?` | 查看全部按键和动作 |

注意：

- `Backspace` / `Ctrl-h` 是“返回上一级目录”，每按一次就把当前根目录的父目录作为新的根，可以连续按一直退到项目根。
- 文件树是 `-drawer` 模式，打开后焦点会进入树窗口；按 `F9` 关闭，或用 `Ctrl-w` 前缀切回代码窗口。
- `D`（回收站）在 Linux 上依赖 `trash-cli`（提供 `trash-put`）或 `gomi`。本机未安装时该操作会报错；
  需要时执行 `sudo dnf install trash-cli`，或者直接用终端 `gio trash 文件名`。
- 文件树只显示目录结构，不是符号树；函数/类大纲仍按 `F8` 用 tagbar。

### 4.5 文件内跳转（vim-sneak）

| 按键 | 功能 |
|---|---|
| `s` + 两个字符 | 向后跳到该两字符组合出现的位置 |
| `S` + 两个字符 | 向前跳 |
| `;` | 跳到下一个匹配 |
| `,` | 跳到上一个匹配 |

### 4.6 其它

| 按键 / 命令 | 功能 |
|---|---|
| `<leader>w` | 保存 |
| `<leader>q` | 退出 |
| `<leader>co` / `<leader>cc` | 打开 / 关闭 quickfix |
| `<leader>?` 或 `:Keys` / `:MyHelp` | 打开内置快捷键速查帮助（等同 `:help myvim` / `:help my`，在帮助窗口按 `q` 直接关闭） |
| `:Readme` | 在分屏中只读打开本 `README.md` 完整文档（按 `q` 直接关闭） |
| `:LspStatus` | 查看所有 LSP server 状态 |
| `:LspStopServer <名字>` | 停止指定 server（如 `:LspStopServer gopls`） |

### 4.7 鼠标

- `set mouse=a`：左键定位、拖动选中、滚轮滚动均正常。
- **鼠标右键已禁用**（默认行为会开始/扩展 Visual 选区，插入模式下也会临时进入 Visual）。
  如想恢复，删除 `~/.vimrc` 末尾的 `<RightMouse>` / `<RightDrag>` / `<RightRelease>` 映射即可。
- 终端 Herdr 自己的右键菜单（已加入复制/粘贴）不是 Vim 的右键，见第十一节。

---

## 五、语言支持

| 语言 | filetype | LSP server | 说明 |
|---|---|---|---|
| Go | `go` | gopls | `go.mod` 所在目录作为项目根；首次打开会加载整个模块 |
| Java | `java` | eclipse-jdt-ls 1.58.0 | 支持 Maven / Gradle 项目，首次导入较慢 |
| TypeScript / JavaScript | `typescript` / `javascript` | typescript-language-server | 在含 `package.json` / `tsconfig.json` / `node_modules` 的目录生效 |
| PHP | `php` | intelephense | 首次打开大项目需要索引时间，索引完成后 `gr` 才完整 |

其它语言（Python、Rust、Vue、YAML 等）：打开对应文件时 vim-lsp-settings 会提示是否安装 server，
也可以手动执行 `:LspInstallServer <server 名>`。安装完成后重新打开文件即可。

---

## 六、日常使用流程示例

```bash
cd ~/projects/my-app
vim                              # 在项目根目录打开 Vim
```

1. `F9` 打开左侧文件树（或 `<leader>e` 定位当前文件），`<leader>ff` 输入文件名片段打开文件；
2. 光标停在函数/类名上按 `gd` 跳转；
3. `gr` 查看这个函数被谁调用；
4. `K` 看文档，`<leader>rn` 改名；
5. `F8` 看文件大纲，`<leader>d` 搜索当前文件符号；
6. `<leader>fg` 全文搜索，`<leader>co` 在 quickfix 里逐个跳转。

---

## 七、维护与更新

### 7.1 插件

```vim
:PlugStatus     " 查看插件状态
:PlugInstall    " 安装 .vimrc 中新增的插件
:PlugUpdate     " 更新所有插件
:PlugClean      " 删除已从 .vimrc 移除的插件
```

更新后建议重启 Vim。若更新导致 vim-lsp 行为异常，可以用 `git -C ~/.vim/plugged/<插件> log` 查看提交并回退。

### 7.2 LSP server

```vim
:LspStatus                        " 查看状态：running / starting / failed
:LspStopServer gopls              " 停止某个 server
:e                                " 重新打开当前文件即可重新启动
:LspInstallServer                 " 为当前文件类型安装 server（Java 例外，见上）
```

### 7.3 升级 gopls

```bash
GOBIN=~/.local/bin go install golang.org/x/tools/gopls@latest
```

### 7.4 清空 tags 缓存

```bash
rm -rf ~/.cache/gutentags
```

重新打开项目文件会自动重建。

---

## 八、常见问题排查

**1. `gd` / `gr` 没反应**

```vim
:set ft?        " 确认文件类型正确（php / go / java / typescript）
:LspStatus      " 确认对应 server 是 running
:messages       " 查看是否有报错
```

- 显示 `starting`：server 还在启动或索引（Java、PHP 大项目首次会慢），稍等再试。
- 显示 `not running` / `failed`：看 `:messages`，或确认 server 可执行文件存在。
- 没有映射：说明该 buffer 没有挂上任何 LSP server，按上面步骤检查。

**2. Go 项目报 `missing go.sum entry`**

gopls 加载失败的信息会来自项目自身，进入项目执行：

```bash
go mod download     # 或 go mod tidy
```

**3. Java 项目第一次打开很慢**

JDTLS 需要导入整个 Maven/Gradle 工程并解析依赖，属正常现象。确认 `:LspStatus` 为 `running` 后等待索引完成即可，之后有缓存。

**4. PHP 大项目 `gr` 结果不全**

intelephense 首次索引未完成。观察状态栏提示，等索引结束后再查；`vendor` 目录也会被索引，项目越大耗时越长。

**5. 右键没反应**

是刻意禁用的，见 4.7 节。

**6. 在 Vim 里执行 `:!mvn` / `:!java` 用的是 JDK 21**

`~/.vimrc` 为 JDTLS 把 `/usr/lib/jvm/java-21/bin` 加到了 Vim 进程的 PATH 前面，仅影响 Vim 的子进程，不影响终端。

**7. fzf 命令找不到**

```bash
ls -l ~/.local/bin/fzf            # 应指向 ~/.fzf/bin/fzf
# 若丢失：
~/.fzf/install --bin
ln -sf ~/.fzf/bin/fzf ~/.local/bin/fzf
```

**8. `F9` 打不开文件树**

```vim
:PlugStatus      " 确认 fern.vim 已安装
:PlugInstall     " 没有则安装
```

`~/.vimrc` 中已把 fern 虚拟 buffer 下的 LSP 根目录回退到 Vim 工作目录，
所以先在文件树里操作、再打开 Go 文件也不会让 gopls 初始化失败。
如果 LSP 状态仍是 `failed`，用 `:e` 重新打开当前文件即可。

**9. `<leader>fg` 没反应 / 搜不到东西**

- 先确认 fzf 窗口有没有弹出来。`<leader>fg` 是交互式搜索，弹出后要**输入关键字**再按 `Enter`，不是在光标处直接搜。
- 搜索范围：fern 窗口用文件树根；普通文件用项目根（`go.mod` / `pom.xml` / `package.json` / `composer.json` / `.git` 等）；无名 buffer 用 `:pwd`。
  如果目录不对，先 `:cd 项目根`。
- ripgrep 默认跳过 `.gitignore` 里的文件，`node_modules`、`vendor`、`target` 等目录搜不到是正常的。
- Space 后如果隔太久才按 `f` / `g`，会超过 `timeoutlen=400` 导致 leader 映射不触发；可加快按键，或调大 `timeoutlen`。
- 确认当前在 **Normal 模式**（这些是 `nnoremap`，插入模式下无效）。

---

## 九、重建 / 迁移到新机器（仓库 `src/` 一键替换）

本仓库 `src/` 目录下已完整备份了所有 Vim 与 Herdr 的改动文件，目录结构如下：

```
src/
├── install.sh                                  # 一键安装 / 替换脚本
├── vim/
│   ├── .vimrc                                  # -> ~/.vimrc
│   ├── doc/
│   │   ├── myvim.txt                           # -> ~/.vim/doc/myvim.txt（内置 :help myvim 手册）
│   │   └── tags                                # -> ~/.vim/doc/tags
│   └── eclipse-jdt-ls/
│       ├── eclipse-jdt-ls                      # -> ~/.local/share/vim-lsp-settings/servers/eclipse-jdt-ls/
│       └── .vim-lsp-settings-version
└── herdr-app/
    ├── keys.json                               # -> ~/.config/herdr-app/keys.json
    ├── layouts/
    │   └── main-copy.json                      # -> ~/.config/herdr-app/layouts/main-copy.json
    └── mods/
        ├── my-menu/                            # -> ~/.config/herdr-app/mods/my-menu/ (Open/Search in Vim)
        │   ├── main.js
        │   ├── open_vim.py
        │   ├── mod.json
        │   ├── jsconfig.json
        │   ├── copy.svg
        │   ├── clipboard.svg
        │   └── vim.svg
        └── my-pane/                            # -> ~/.config/herdr-app/mods/my-pane/ (顶部完整路径 + 快捷键监听)
            ├── main.js
            ├── mod.json
            ├── jsconfig.json
            ├── close.svg
            ├── split-down.svg
            ├── split-right.svg
            ├── unzoom.svg
            └── zoom.svg
```

### 9.1 一键安装 / 覆盖配置

在新机器克隆本仓库后，直接执行：

```bash
bash src/install.sh
```

该脚本会自动完成：
1. 复制 `src/vim/.vimrc` 到 `~/.vimrc`，复制 `src/vim/doc/myvim.txt` 到 `~/.vim/doc/`，复制 `README.md` 到 `~/.vim/README.md`，自动下载 `vim-plug`（若缺失）并生成 `:helptags ~/.vim/doc`。
2. 复制 `src/herdr-app/` 下的 `keys.json`、`layouts/main-copy.json`、`mods/my-menu/`、`mods/my-pane/` 到 `~/.config/herdr-app/`，自动执行 `herdr-app check` 并切换到 `main-copy` 布局。

### 9.2 首次装机外部工具与 LSP 安装步骤

1. 执行完 `bash src/install.sh` 后，打开 Vim 执行 `:PlugInstall` 安装插件；
2. 安装外部工具：`universal-ctags`、`ripgrep`、`node`、`go`、JDK 21；
3. 安装 fzf：

   ```bash
   git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf
   ~/.fzf/install --bin
   ln -sf ~/.fzf/bin/fzf ~/.local/bin/fzf
   ```

4. 安装 gopls：

   ```bash
   GOBIN=~/.local/bin go install golang.org/x/tools/gopls@latest
   ```

5. 安装其它 LSP server（以当前机器的路径为例，任意空目录中执行对应脚本即可）：

   ```bash
   mkdir -p ~/.local/share/vim-lsp-settings/servers/intelephense
   cd ~/.local/share/vim-lsp-settings/servers/intelephense
   sh ~/.vim/plugged/vim-lsp-settings/installer/install-intelephense.sh

   mkdir -p ~/.local/share/vim-lsp-settings/servers/typescript-language-server
   cd ~/.local/share/vim-lsp-settings/servers/typescript-language-server
   sh ~/.vim/plugged/vim-lsp-settings/installer/install-typescript-language-server.sh
   ```

6. Java（JDK 21 环境）：

   ```bash
   mkdir -p ~/.local/share/vim-lsp-settings/servers/eclipse-jdt-ls
   cd ~/.local/share/vim-lsp-settings/servers/eclipse-jdt-ls
   curl -LO https://download.eclipse.org/jdtls/milestones/1.58.0/jdt-language-server-1.58.0-202604151538.tar.gz
   tar xzf jdt-language-server-1.58.0-202604151538.tar.gz
   curl -LO https://projectlombok.org/downloads/lombok.jar
   ```

   然后再次运行 `bash src/install.sh` 即可将 `src/vim/eclipse-jdt-ls/` 下的启动脚本与版本号自动同步进去。

---

## 十、快速命令备忘

```
:Files / <leader>ff      找文件
:Rg / <leader>fg         全文搜索
:BTags / <leader>ft      当前文件函数
:Fern . -drawer -toggle / F9   文件树
:LspStatus               查看 LSP
:TagbarToggle / F8       大纲
:PlugUpdate              更新插件
:grep 关键字 + :copen     quickfix 搜索
```

---

## 十一、Herdr 终端增强（复制 / 粘贴 / Open in Vim / 顶部完整文件路径）

Herdr 默认的终端右键菜单只有分屏、缩放、关闭等，没有复制/粘贴和用 Vim 打开代码文件；且面板上方默认只显示项目目录。已在个人副本中补齐以下增强功能：

```
Copy                    ctrl-shift-c
Paste                   ctrl-shift-v
Open in Vim             alt-v
Search in Vim           alt-f
─────────────────────────────────────
Split right             ctrl-shift-o
Split down              ctrl-shift-e
Zoom                    ctrl-shift-z
Send right-clicks to pane
─────────────────────────────────────
Close pane              ctrl-shift-x
```

- 这是 **Herdr 的终端菜单**，不是 Vim 的右键（Vim 右键仍为禁用状态，见 4.7）。
- vim、tmux、部分 TUI 智能体等程序自己接管鼠标时，用 **Shift + 左键拖选** 并用 **Shift + 右键** 打开此菜单。
- 快捷键：
  - **`Alt + V`**（备选 `Ctrl + Shift + G`）：**Open in Vim**（直接用 Vim 打开选中的代码文件与行号）
  - **`Alt + F`**：**Search in Vim**（将选中的文字在当前目录下进行 Ripgrep + FZF 全文搜索并实时预览代码）

### 11.1 Open in Vim & Search in Vim（快捷键 & 右键，所有智能体通用）

在 Claude Code、Antigravity、Codex、OpenCode、Kimi 或任意终端（包括 Vim 自身）里：
1. **鼠标拖选（或双击）文字**（如果程序接管了鼠标，按住 `Shift` 拖选）。
2. 执行对应操作：
   - **打开代码文件**：直接按 **`Alt + V`**（或右键点击 **`Open in Vim`**）。
   - **当前目录全文搜索选中文字**：直接按 **`Alt + F`**（或右键点击 **`Search in Vim`**），会自动定位到当前目录并在 Vim 中弹出 FZF + Ripgrep 全文搜索窗口（左侧列出所有匹配文件与行号，右侧实时高亮预览上下文代码，按 `Enter` 直接跳转到对应文件行）。
   - 补充：在 Vim 内部也可以用 `v` 选中文字后按 **`空格 + fg`**（`<leader>fg`）直接全文搜索所选文字。

**窗口复用逻辑（当前 Space 内）：**
- **当前 Tab 已有 Vim 分屏**：自动取消 Zoom（若已最大化）、聚焦到该 Vim 分屏，通过 Ex 模式（`Ctrl-\ Ctrl-n g Q`）切换回主编辑窗口（避开左侧 `fern` 文件树或右侧 `tagbar` 侧边栏），把工作目录切到项目根目录并执行 `:edit` + 跳转到对应行号居中显示。
- **当前 Space 的其他 Tab 已有 Vim 窗口**（例如 Tab 1 是 Claude Code / Antigravity，Tab 2 是 Vim）：自动切换到该 Vim 所在的 Tab（`tab.select`）、聚焦 Vim 面板并打开目标文件与行号。
- **当前 Tab 已有空闲 Shell 分屏**：直接在该空闲终端里 `cd 项目根目录 && vim +行号 文件路径`。
- **当前 Space 尚无 Vim 窗口**：自动在**右侧新建分屏**（`Split right`）并用 Vim 打开该文件（自动 `cd` 到项目根目录，使得 fzf / Fern / Ripgrep 直接生效）。

**支持识别的文件名格式：**
- 相对路径或绝对路径：`src/main.js`、`/path/to/project/README.md`、`~/.vimrc`
- 带行号 / 列号 / 中文行号：`src/main.js:42`、`src/main.js:42:10`、`src/main.js#L42`、`src/main.js (line 42)`、`ExceptionListener.php 第 68 行`
- Markdown 链接：`[main.js](file:///path/to/main.js#L10-L20)`
- Claude Code 工具头：`Update(src/main.js)`、`Read(config/application.php)`、`a/src/main.js`、`b/src/main.js`
- **仅选中文件名或类名（不含目录/后缀）**：例如只选中 `application.php`、`callback_worker.go:210`、`ExchangeController:300`，会自动在当前智能体工作目录 / Git 仓库根目录下通过终端上下文与 `rg --files` 查找匹配路径。
- **跨行截断路径**：终端窄屏折行或带 `│` 边框符号的多行路径会自动拼接还原。

### 11.2 Vim 窗口顶部栏显示当前文件完整路径

Herdr 默认面板顶部栏（`pane` mod）固定显示终端当前工作目录（`p.cwd`，即项目路径）。通过以下两步改为在 Vim 窗口上方实时显示**当前打开文件的完整绝对路径**：

1. **`~/.vimrc` 同步终端标题**：
   开启 `set title`，并通过 `vim_title_fullpath` 自动命令组监听 `VimEnter,BufEnter,BufWinEnter,BufFilePost,DirChanged`，在普通代码窗口中（自动跳过 `fern`、`tagbar`、`qf` 等侧边栏）将 `&titlestring` 设为 `expand('%:p')`。
2. **`my-pane` 自定义面板顶部栏**：
   在 `~/.config/herdr-app/mods/my-pane/main.js` 中检测当 `p.program.key` 为 `vim`/`nvim` 且终端标题 `p.title` 为文件路径时，顶部栏左侧显示 `Vim`，右侧展示完整文件路径（替代默认的 `folder(p.cwd)`）。

### 11.3 为什么用副本

Herdr 自带的 `menu`、`pane` mod 和 `main` 布局都是只读的：直接改会在下次启动时被还原（改动会被挪到 `*-edited`）。所以按官方推荐先克隆再改：

```bash
herdr-app do mod.clone '{"name":"menu","as":"my-menu"}'
herdr-app do mod.clone '{"name":"pane","as":"my-pane"}'
herdr-app do layout.clone '{"name":"main","as":"main-copy"}'
```

### 11.4 改动的文件

| 文件 | 改动 |
|---|---|
| `~/.config/herdr-app/keys.json` | 在 `global` 和 `terminal` 下绑定 `"alt-v": "my-pane.open_vim"` 与 `"ctrl-shift-g": "my-pane.open_vim"` |
| `~/.config/herdr-app/mods/my-menu/main.js` | pane 右键菜单增加 `Copy` / `Paste` / `Open in Vim`（显示快捷键 `alt-v`）；点击后先聚焦目标 pane 并执行 `terminal.copy`，再异步读取剪贴板调用 `open_vim.py` |
| `~/.config/herdr-app/mods/my-menu/open_vim.py` | 解析剪贴板与终端屏幕中的文件路径/行号，在当前 Tab 或同 Space 的 Vim 标签页中打开文件（支持 Ex 模式 `:edit` 复用已有 Vim 并刷新终端标题） |
| `~/.config/herdr-app/mods/my-menu/mod.json` | 调整菜单 overlay 高度至 `295` 以容纳新增菜单项 |
| `~/.config/herdr-app/mods/my-menu/copy.svg`、`clipboard.svg`、`vim.svg` | 菜单图标 |
| `~/.config/herdr-app/mods/my-pane/main.js` | ① 自定义面板顶部状态栏：Vim 窗口上方显示当前打开文件的完整绝对路径；② 通过 `nextCommand()` 响应 `my-pane.open_vim` 快捷键，对当前聚焦面板执行复制并调用 `open_vim.py` |
| `~/.config/herdr-app/layouts/main-copy.json` | 根节点加入 `"terminal_menu": "my-menu"`，并将 pane 顶部栏 mod 改为 `"mod": "my-pane"` |
| `~/.vimrc` | 开启 `set title` 并通过 `vim_title_fullpath` 自动命令将终端标题实时更新为当前文件的完整路径（`expand('%:p')`） |

### 11.5 验证与日志排查

```bash
herdr-app check ~/.config/herdr-app/mods/my-menu   # check passed
herdr-app check ~/.config/herdr-app/mods/my-pane   # check passed
herdr-app status                                   # errors 为空
tail -f /tmp/open_vim.log                          # 查看 Open in Vim 解析与跳转日志
```

### 11.6 维护与撤销

- 当前使用布局 `main-copy`（`ctrl-shift-l` 中可见）。Herdr 更新 `main` 布局时**不会**同步到这个副本；想要最新主布局时，重新 clone 一次并在根节点补上 `"terminal_menu": "my-menu"` 以及將 pane header 指向 `"mod": "my-pane"`。
- 修改快捷键：直接编辑 `~/.config/herdr-app/keys.json` 中指向 `"my-pane.open_vim"` 的键位即可立即生效。
- 恢复原样：切回 `main` 布局（`ctrl-shift-l`），或删除 `~/.config/herdr-app/mods/my-menu`、`~/.config/herdr-app/mods/my-pane` 与 `~/.config/herdr-app/layouts/main-copy.json`。
- 改完 mod 文件或 `keys.json` 保存即热重载，无需重启 Herdr。
