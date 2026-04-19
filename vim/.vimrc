set nobackup 
set nocp
set softtabstop=4
set tabstop=4
set shiftwidth=4
set et
set ignorecase
set hlsearch
set nowrap

set ai
set ruler
set showcmd
set incsearch
set dir=/tmp       " Make swap live in the %TEMP% directory
syn on

" Load the color scheme
if has('gui_running')
    colo inkpot
else    
    colo default
    hi Normal ctermbg=black ctermfg=white
endif

" Setup some common abbreviations 
iabbrev #c //==============================================================================

" Filetype settings
filetype plugin on
filetype indent on