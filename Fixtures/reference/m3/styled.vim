set nocompatible
set nomodeline noswapfile nobackup noundofile viminfo=
set noruler noshowcmd noshowmode shortmess+=I
set encoding=utf-8 nofoldenable mouse= belloff=all
set ttimeout ttimeoutlen=10
set number numberwidth=3 laststatus=2 notermguicolors
let &statusline = ' %f%=%l:%c '
filetype on
syntax on

function! s:mark_frame() abort
  call writefile([&background, &filetype, b:current_syntax, &t_Co], 'vim-proof.txt')
  normal! 5G$
endfunction
command! Frame call <SID>mark_frame()
