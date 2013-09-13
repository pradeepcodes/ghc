echo $PATH 
brew update
brew install autoconf automake
brew install docbook

#install llvm
wget llvm.org/releases/3.0/clang+llvm-3.0-x86_64-apple-darwin11.tar.gz && tar xvfz clang+llvm-3.0-x86_64-apple-darwin11.tar.gz && mv clang+llvm-3.0-x86_64-apple-darwin11 llvm
export PATH=`pwd`\llvm:$PATH

#install haskell-platform
wget lambda.haskell.org/platform/download/2013.2.0.0/Haskell%20Platform%202013.2.0.0%2064bit.pkg && sudo installer -pkg "Haskell Platform 2013.2.0.0 64bit.pkg" -target /
ls /Library/Haskell/bin
export PATH=/Library/Haskell/bin:$PATH

