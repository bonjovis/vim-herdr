#!/usr/bin/env bash
# 一键安装 / 更新个人 Vim 与 Herdr (herdr & herdr-app) 配置
# 用法：在仓库根目录或任意位置执行 bash src/install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HERDR_TUI_DIR="${HERDR_CONFIG_DIR:-${HOME}/.config/herdr}"
HERDR_APP_DIR="${HERDR_APP_HOME:-${HOME}/.config/herdr-app}"

echo "==> [1/5] 安装 Vim 配置 (~/.vimrc)、AI 桥接脚本与内置帮助文档..."
mkdir -p "${HOME}/.vim/doc" "${HOME}/.vim/autoload" "${HOME}/.vim/scripts"
rm -f "${HOME}/.vimrc"
cp -f "${SCRIPT_DIR}/vim/.vimrc" "${HOME}/.vimrc"
cp -f "${SCRIPT_DIR}/vim/autoload/herdr_ai.vim" "${HOME}/.vim/autoload/herdr_ai.vim"
cp -f "${SCRIPT_DIR}/vim/scripts/ask_ai.py" "${HOME}/.vim/scripts/ask_ai.py"
chmod +x "${HOME}/.vim/scripts/ask_ai.py"
cp -f "${SCRIPT_DIR}/vim/doc/myvim.txt" "${HOME}/.vim/doc/myvim.txt"
if [[ -f "${REPO_DIR}/README.md" ]]; then
  cp -f "${REPO_DIR}/README.md" "${HOME}/.vim/README.md"
fi

if [[ ! -f "${HOME}/.vim/autoload/plug.vim" ]]; then
  echo "    未检测到 vim-plug，正在下载 ~/.vim/autoload/plug.vim ..."
  curl -fLo "${HOME}/.vim/autoload/plug.vim" --create-dirs \
    https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim || true
fi

if command -v vim >/dev/null 2>&1; then
  if [[ ! -d "${HOME}/.vim/plugged/vim-gitgutter" ]] && command -v git >/dev/null 2>&1; then
    echo "    正在安装新增插件 airblade/vim-gitgutter ..."
    git clone --depth 1 https://github.com/airblade/vim-gitgutter.git "${HOME}/.vim/plugged/vim-gitgutter" || true
  fi
  vim -Nu "${HOME}/.vimrc" -es -c "silent! helptags ~/.vim/doc" -c "silent! helptags ~/.vim/plugged/vim-gitgutter/doc" -c "qall!" || true
fi

echo "==> [2/5] 同步 Java JDTLS 启动脚本（若已存在 jdtls 目录）..."
JDTLS_DIR="${HOME}/.local/share/vim-lsp-settings/servers/eclipse-jdt-ls"
if [[ -d "${JDTLS_DIR}" ]]; then
  cp -f "${SCRIPT_DIR}/vim/eclipse-jdt-ls/eclipse-jdt-ls" "${JDTLS_DIR}/eclipse-jdt-ls"
  chmod +x "${JDTLS_DIR}/eclipse-jdt-ls"
  cp -f "${SCRIPT_DIR}/vim/eclipse-jdt-ls/.vim-lsp-settings-version" "${JDTLS_DIR}/.vim-lsp-settings-version"
fi

echo "==> [3/5] 安装 Herdr (TUI) 配置与 vim-open 插件 (${HERDR_TUI_DIR})..."
mkdir -p "${HERDR_TUI_DIR}/plugins/vim-open"
cp -f "${SCRIPT_DIR}/herdr/config.toml" "${HERDR_TUI_DIR}/config.toml"
cp -f "${SCRIPT_DIR}/herdr/plugins/vim-open/herdr-plugin.toml" "${HERDR_TUI_DIR}/plugins/vim-open/herdr-plugin.toml"
cp -f "${SCRIPT_DIR}/herdr-app/mods/my-menu/open_vim.py" "${HERDR_TUI_DIR}/plugins/vim-open/open_vim.py"
chmod +x "${HERDR_TUI_DIR}/plugins/vim-open/open_vim.py"

if command -v herdr >/dev/null 2>&1; then
  herdr plugin link "${HERDR_TUI_DIR}/plugins/vim-open" >/dev/null 2>&1 || true
  herdr plugin enable vim-open >/dev/null 2>&1 || true
  herdr server reload-config >/dev/null 2>&1 || true
fi

echo "==> [4/5] 安装 Herdr-App 快捷键、布局与自定义组件 (${HERDR_APP_DIR})..."
mkdir -p "${HERDR_APP_DIR}/layouts" \
         "${HERDR_APP_DIR}/mods/my-menu" \
         "${HERDR_APP_DIR}/mods/my-pane"

cp -f "${SCRIPT_DIR}/herdr-app/keys.json" "${HERDR_APP_DIR}/keys.json"
cp -f "${SCRIPT_DIR}/herdr-app/layouts/main-copy.json" "${HERDR_APP_DIR}/layouts/main-copy.json"
cp -rf "${SCRIPT_DIR}/herdr-app/mods/my-menu/." "${HERDR_APP_DIR}/mods/my-menu/"
cp -rf "${SCRIPT_DIR}/herdr-app/mods/my-pane/." "${HERDR_APP_DIR}/mods/my-pane/"
chmod +x "${HERDR_APP_DIR}/mods/my-menu/open_vim.py"

echo "==> [5/5] 校验 Herdr / Herdr-App 组件状态..."
if command -v herdr >/dev/null 2>&1; then
  herdr plugin list || true
fi
if command -v herdr-app >/dev/null 2>&1; then
  herdr-app check "${HERDR_APP_DIR}/mods/my-menu" || true
  herdr-app check "${HERDR_APP_DIR}/mods/my-pane" || true
  herdr-app do layout.switch '{"name":"main-copy"}' >/dev/null 2>&1 || true
fi

echo "==> 安装/替换完成！"
echo "    - 首次在新机器使用 Vim 请在 Vim 中执行 :PlugInstall 安装插件"
echo "    - 在 Vim 中按 <Space>? 或执行 :Keys / :help myvim 可查看快捷键速查手册"
