echo $PATH 
pwd
brew install autoconf automake

#install llvm
wget llvm.org/releases/3.0/clang+llvm-3.0-x86_64-apple-darwin11.tar.gz && tar xvfz clang+llvm-3.0-x86_64-apple-darwin11.tar.gz && sudo mv clang+llvm-3.0-x86_64-apple-darwin11 /usr/local/llvm


#install haskell-platform
wget lambda.haskell.org/platform/download/2013.2.0.0/Haskell%20Platform%202013.2.0.0%2064bit.pkg && sudo installer -pkg "Haskell Platform 2013.2.0.0 64bit.pkg" -target /

#update cabal and install any other deps
cabal update
cabal install terminfo

#get ghc ios wrapper scripts
sudo git clone https://github.com/ghc-ios/ghc-ios-scripts.git /usr/local/ghc-ios-scripts