echo $PATH
./sync-all --no-dph get
perl boot
./configure --target=i386-apple-darwin11 --prefix=/usr/local/ghc-ios-sim/
make
sudo mkdir -p /usr/local/ghc-ios-sim/
sudo make install
