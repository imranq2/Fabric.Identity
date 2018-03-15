﻿/*
Do not change the database path or name variables.
Any sqlcmd variables will be properly substituted during 
build and deployment.
*/
ALTER DATABASE [$(DatabaseName)]
ADD LOG FILE
(
	NAME = [HCFabricIdentityLogFile1],
	FILENAME = '$(FabricIdentityLogMountPoint)\HC$(DatabaseName)LogFile1.ldf',
	SIZE = 100 MB,
	FILEGROWTH = 10%
)

