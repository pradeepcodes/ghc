echo $PATH
./sync-all --no-dph get
perl boot
./configure --target=i386-apple-darwin11 --prefix=/usr/local/ghc-ios-sim/ --with-gcc=i386-apple-darwin11-gcc
make -j5
sudo mkdir -p /usr/local/ghc-ios-sim/
sudo make install