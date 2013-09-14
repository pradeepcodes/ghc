echo $PATH
./sync-all --no-dph get
perl boot
./configure
make -j5
sudo mkdir -p /usr/local/ghc-normal/
sudo make install