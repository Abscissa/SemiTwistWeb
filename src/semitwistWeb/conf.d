module semitwistWeb.conf;

import std.conv;
import std.exception;

import sdlang;
import vibe.mail.smtp : SMTPAuthType, SMTPConnectionType;
import semitwistWeb.util;

private Conf conf_;
static @property const(Conf) conf()
{
	return conf_;
}
static @property Tag confSdlRoot()
{
	return conf_.sdlRoot;
}
void loadConf(string configFile = null)
{
	conf_.load(configFile);
}

struct Conf
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

	Tag sdlRoot;

	void load(string configFile = null)
	{
		if(configFile == "")
		{
			import std.file : thisExePath;
			import std.path : dirName;
			configFile = thisExePath.dirName ~ "/semitwistweb.conf.sdl";
		}

		auto root = parseFile(configFile);
		this.sdlRoot = root;
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
			urlBase.length > 0  &&
			urlBase[0  ] == '/' &&
			urlBase[$-1] == '/',
			"urlBase must start and end with a slash"
		);
		enforce!ValidationException(
			host.strip().length > 0,
			"host cannot not be blank"
		);
		enforce!ValidationException(
			host.strip() == host,
			"host cannot have leading or trailing whitespace"
		);
		enforce!ValidationException(
			host[$-1] != '/',
			"host cannot end with a slash"
		);
		enforce!ValidationException(
			host.toLower().startsWith("http://") ||
			host.toLower().startsWith("https://"),
			"host must begin with either http:// or https://"
		);

		staticsUrl = urlBase ~ staticsVirtualPath;
	}
}
