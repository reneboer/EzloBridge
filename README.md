# EzloBridge
A bridge running on openLuup to make the Ezlo controlled devices available on openLuup with all its great plugins. It is based on the VeraBridge that is included with openLuup. 

This version is early Beta. 

To connect you need to enter the user id and password, hub IP address and serial #. Enter these in the Settings tab. At first connect an internet connection is needed to authenticate and obtain a token. As long as the token is valid, all communications are local. When the token has expired a luup reload should get you connected again.

To-do's:
- Test expired token handling
- Better lock support.

Note that you need to have the bitop and cjson Lua library installed:
```
sudo apt-get install lua-bitop
sudo apt-get install lua-cjson
``` 
