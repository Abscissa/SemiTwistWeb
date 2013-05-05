/// Written in the D programming language.

module semitwistWeb.email;

import vibe.vibe;
import semitwist.util.all;
import semitwistWeb.db;
import semitwistWeb.util;
mixin importConf;

private SmtpClientSettings _smtpClientSettings;
@property SmtpClientSettings smtpClientSettings()
{
	if(!_smtpClientSettings)
	{
		_smtpClientSettings = new SmtpClientSettings();
		_smtpClientSettings.authType       = Conf.smtpAuthType;
		_smtpClientSettings.connectionType = Conf.smtpConnectionType;
		_smtpClientSettings.host           = Conf.smtpHost;
		//_smtpClientSettings.localname      = Conf.smtpLocalName;
		_smtpClientSettings.port           = Conf.smtpPort;
		_smtpClientSettings.username       = Conf.smtpUser;
		_smtpClientSettings.password       = Conf.smtpPass;
	}
	
	return _smtpClientSettings;
}
