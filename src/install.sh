#!/usr/bin/env bash
# 一键安装 / 更新个人 Vim 与 Herdr 配置
# 用法：在仓库根目录或任意位置执行 bash src/install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HERDR_DIR="${HERDR_APP_HOME:-${HOME}/.config/herdr-app}"

echo "==> [1/4] 安装 Vim 配置 (~/.vimrc)、AI 桥接脚本与内置帮助文档..."
mkdir -p "${HOME}/.vim/doc" "${HOME}/.vim/autoload" "${HOME}/.vim/scripts"
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
  vim -Nu "${HOME}/.vimrc" -es -c "silent! helptags ~/.vim/doc" -c "qall!" || true
fi

echo "==> [2/4] 同步 Java JDTLS 启动脚本（若已存在 jdtls 目录）..."
JDTLS_DIR="${HOME}/.local/share/vim-lsp-settings/servers/eclipse-jdt-ls"
if [[ -d "${JDTLS_DIR}" ]]; then
  cp -f "${SCRIPT_DIR}/vim/eclipse-jdt-ls/eclipse-jdt-ls" "${JDTLS_DIR}/eclipse-jdt-ls"
  chmod +x "${JDTLS_DIR}/eclipse-jdt-ls"
  cp -f "${SCRIPT_DIR}/vim/eclipse-jdt-ls/.vim-lsp-settings-version" "${JDTLS_DIR}/.vim-lsp-settings-version"
fi

echo "==> [3/4] 安装 Herdr 快捷键、布局与自定义组件 (${HERDR_DIR})..."
mkdir -p "${HERDR_DIR}/layouts" \
         "${HERDR_DIR}/mods/my-menu" \
         "${HERDR_DIR}/mods/my-pane"

cp -f "${SCRIPT_DIR}/herdr-app/keys.json" "${HERDR_DIR}/keys.json"
cp -f "${SCRIPT_DIR}/herdr-app/layouts/main-copy.json" "${HERDR_DIR}/layouts/main-copy.json"
cp -rf "${SCRIPT_DIR}/herdr-app/mods/my-menu/." "${HERDR_DIR}/mods/my-menu/"
cp -rf "${SCRIPT_DIR}/herdr-app/mods/my-pane/." "${HERDR_DIR}/mods/my-pane/"
chmod +x "${HERDR_DIR}/mods/my-menu/open_vim.py"

echo "==> [4/4] 校验 Herdr 组件状态..."
if command -v herdr-app >/dev/null 2>&1; then
  herdr-app check "${HERDR_DIR}/mods/my-menu" || true
  herdr-app check "${HERDR_DIR}/mods/my-pane" || true
  herdr-app do layout.switch '{"name":"main-copy"}' >/dev/null 2>&1 || true
fi

echo "==> 安装/替换完成！"
echo "    - 首次在新机器使用 Vim 请在 Vim 中执行 :PlugInstall 安装插件"
echo "    - 在 Vim 中按 <Space>? 或执行 :Keys / :help myvim 可查看快捷键速查手册"
