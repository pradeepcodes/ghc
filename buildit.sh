echo $PATH
./sync-all --no-dph get
perl boot
./configure --prefix=/usr/local/ghc-normal/
make -j5
sudo mkdir -p /usr/local/ghc-normal/
sudo make install