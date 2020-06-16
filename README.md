# EzloBridge
A bridge running on openLuup to make the Ezlo controlled devices available on openLuup with all its great plugins.

This version is early Beta.

To connect you need to enter the user id and password, hub IP address and serial #. At first connect an internet conneciton is needed to authenticate and obtain a token. As long as the token is valid, all communications are local.

To-do's:
- Add Refresh command to pull full config from Ezlo hub again.
- Test expired token handling
- Better HVAC and lock support.
