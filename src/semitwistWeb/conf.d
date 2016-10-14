module semitwistWeb.conf;

import std.conv;
import std.exception;

import sdlang;
import vibe.mail.smtp : SMTPAuthType, SMTPConnectionType;
import semitwistWeb.util;

private ConfStruct conf_;
static @property const(ConfStruct) Conf()
{
	return conf_;
}
void loadConf(string configFile = null)
{
	conf_.load(configFile);
}

struct ConfStruct
{
	string host;
	string urlBase;

	string staticsRealPath;
	string staticsVirtualPath;

	// DB Connection Settings
	string dbHost;
	ushort dbPort;
	string dbUser;
	string dbPass;
	string dbName;

	// SMTP Settings
	SMTPAuthType       smtpAuthType;
	SMTPConnectionType smtpConnectionType;
	string smtpHost;
	//string smtpLocalName;
	ushort smtpPort;
	string smtpUser;
	string smtpPass;

	string staticsUrl;

	void load(string configFile = null)
	{
		if(configFile == "")
		{
			import std.file : thisExePath;
			import std.path : dirName;
			configFile = thisExePath.dirName ~ "/semitwistweb.conf.sdl";
		}

		auto root = parseFile(configFile);
		host               = root.expectTagValue!string("host");
		urlBase            = root.expectTagValue!string("urlBase");
		staticsRealPath    = root.expectTagValue!string("staticsRealPath");
		staticsVirtualPath = root.expectTagValue!string("staticsVirtualPath");

		dbHost             = root.expectTagValue!string("dbHost");
		dbPort             = root.expectTagValue!int("dbPort").to!ushort;
		dbUser             = root.expectTagValue!string("dbUser");
		dbPass             = root.expectTagValue!string("dbPass");
		dbName             = root.expectTagValue!string("dbName");

		smtpAuthType       = root.expectTagValue!string("smtpAuthType").toEnum!SMTPAuthType;
		smtpConnectionType = root.expectTagValue!string("smtpConnectionType").toEnum!SMTPConnectionType;
		//smtpLocalName      = root.getTagValue!string("smtpLocalName");
		smtpPort           = root.expectTagValue!int("smtpPort").to!ushort;
		smtpUser           = root.expectTagValue!string("smtpUser");
		smtpPass           = root.expectTagValue!string("smtpPass");

		// Validate:
		import std.string;
		enforce!ValidationException(
			Conf.urlBase.length > 0  &&
			Conf.urlBase[0  ] == '/' &&
			Conf.urlBase[$-1] == '/',
			"urlBase must start and end with a slash"
		);
		enforce!ValidationException(
			Conf.host.strip().length > 0,
			"host cannot not be blank"
		);
		enforce!ValidationException(
			Conf.host.strip() == Conf.host,
			"host cannot have leading or trailing whitespace"
		);
		enforce!ValidationException(
			Conf.host[$-1] != '/',
			"host cannot end with a slash"
		);
		enforce!ValidationException(
			Conf.host.toLower().startsWith("http://") ||
			Conf.host.toLower().startsWith("https://"),
			"host must begin with either http:// or https://"
		);

		staticsUrl = Conf.urlBase ~ Conf.staticsVirtualPath;
	}
}
