echo $PATH
./sync-all --no-dph get
perl boot
./configure --target=arm-apple-darwin10 --prefix=/usr/local/ghc-ios/
make -j5
sudo mkdir -p /usr/local/ghc-ios/
sudo make install