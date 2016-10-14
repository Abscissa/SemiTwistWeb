/// Written in the D programming language.

module semitwistWeb.email;

import vibe.vibe;
import semitwist.util.all;
import semitwistWeb.conf;
import semitwistWeb.db;
import semitwistWeb.util;

private SMTPClientSettings _smtpClientSettings;
@property SMTPClientSettings smtpClientSettings()
{
	if(!_smtpClientSettings)
	{
		_smtpClientSettings = new SMTPClientSettings();
		_smtpClientSettings.authType       = conf.smtpAuthType;
		_smtpClientSettings.connectionType = conf.smtpConnectionType;
		_smtpClientSettings.host           = conf.smtpHost;
		//_smtpClientSettings.localname      = conf.smtpLocalName;
		_smtpClientSettings.port           = conf.smtpPort;
		_smtpClientSettings.username       = conf.smtpUser;
		_smtpClientSettings.password       = conf.smtpPass;
	}
	
	return _smtpClientSettings;
}
