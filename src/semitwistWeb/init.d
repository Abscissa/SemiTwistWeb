/// Written in the D programming language.

module semitwistWeb.init;

import std.getopt;
import std.stdio;
import core.memory;

import vibe.vibe;
import vibe.core.args;
import vibe.core.connectionpool;
import mysql.db;

import semitwist.util.all;

import semitwistWeb.db;
import semitwistWeb.doc;
import semitwistWeb.handler;
import semitwistWeb.session;
import semitwistWeb.util;
mixin importConf;

bool initDB        = false;
bool clearSessions = false;
bool noCacheStatic = false;
bool noStatic      = false;
ushort port        = 8080;
string[] bindAddresses;
string logFile     = "";

//TODO: Find/create a tool to monitor the logfile and send emails for each new entry.

alias int function(ref HTTPServerSettings, ref URLRouter) CustomPostInit;

// This is a modification of vibe.d's built-in main().
int semitwistWebMain(CustomSession, CustomHandler, UserDBOTypes...)
	(string[] args, CustomPostInit customPostInit, LockedConnection!Connection delegate() openDB)
{
	debug runDocHelperUnittest();

	dbHelperOpenDB = openDB;
	BaseHandler.addAppContextCallback = &CustomHandler.addAppContext;

	if(auto errlvl = processCustomCmdLine(args) != -1)
		return errlvl;

	if(initDB)
	{
		initializeDB();
		return 0;
	}
	
	if(auto errlvl = init!(CustomSession, CustomHandler, UserDBOTypes)(customPostInit) != -1)
		return errlvl;

	stLogInfo("Running event loop...");
	try {
		return runEventLoop();
	} catch( Throwable th ){
		stLogError("Unhandled exception in event loop: ", th);
		return 1;
	}
}

/// Returns: -1 normally, or else errorlevel to exit with
private int processCustomCmdLine(ref string[] args)
{
	readOption("init-db",           &initDB,              "Init the DB and exit (THIS WILL DESTROY ALL DATA!)");
	readOption("clear-sessions",    &clearSessions,       "Upon startup, clear sessions in DB insetad of resuming them.");
	readOption("port",              &port,                "Port to bind.");
	string bindAddress;
	while(readOption("ip", &bindAddress, "IP address to bind. (Can be specified multiple times)"))
		bindAddresses ~= bindAddress;
	readOption("no-cache",          &BaseHandler.noCache, "Disable internal page caching. (Useful during development)");
	readOption("no-cache-static",   &noCacheStatic,       "Set HTTP headers on static files to disable caching. (Useful during development)");
	readOption("no-static",         &noStatic,            "Disable serving of static files.");
	readOption("log",               &logFile,             "Set logfile.");

	readOption("insecure",          &BaseHandler.allowInsecure,   "Allow non-HTTPS requests.");
	readOption("insecure-cookies",  &useInsecureCookies,          "Don't set SECURE attribute on session cookies.");
	readOption("public-debug-info", &BaseHandler.publicDebugInfo, "Display uncaught exceptions and stack traces to user. (Useful during development)");
	readOption("log-sql",           &dbHelperLogSql,              "Log all SQL statements executed. (Useful during development)");
	
	try
	{
		if(!finalizeCommandLineOptions())
			return 0;
	}
	catch(Exception e)
	{
		stLogError("Error processing command line: ", e.msg);
		return 1;
	}
	
	if(bindAddresses.length == 0)
		bindAddresses = ["0.0.0.0", "::"];
	
	setLogFormat(FileLogger.Format.threadTime);
	if(logFile != "")
		setLogFile(logFile, LogLevel.info);
	
	return -1;
}

/// Returns: -1 normally, or else errorlevel to exit with
private int init(CustomSession, CustomHandler, UserDBOTypes...)
	(CustomPostInit customPostInit)
{
	version(RequireSecure)
	{
		if(Handler.allowInsecure || useInsecureCookies || Handler.publicDebugInfo)
		{
			stLogError("This was compiled with -version=RequireSecure, therefore the following flags are disabled: --insecure --insecure-cookies --public-debug-info");
			return 1;
		}
	}
	
	// Warn about --insecure-cookies
	if(useInsecureCookies)
		stLogWarn("Used --insecure-cookies: INSECURE cookies are ON! Session cookies will not use the Secure attribute!");

	// Warn about --insecure
	if(BaseHandler.allowInsecure)
		stLogWarn("Used --insecure: INSECURE mode is ON! HTTPS will NOT be forced!");

	// Warn about HTTP
	if(Conf.host.toLower().startsWith("http://"))
	{
		if(BaseHandler.allowInsecure)
			stLogWarn(
				"Non-relative URLs are set to HTTP, not HTTPS! ",
				"If you did not intend this, change Conf.host and recompile."
			);
		else
		{
			// Require --insecure for non-HTTPS
			stLogError(
				"Conf.host is HTTP instead of HTTPS. THIS IS NOT RECOMMENDED. ",
				"If you wish to allow this anyway, you must use the --insecure flag. ",
				"Note that this will cause non-relative application URLs to be HTTP instead of HTTPS."
			);
			return 1;
		}
	}
	
	{
		scope(failure)
		{
			stLogError(
				"There was an error building the basic pages.\n",
				import("dbTroubleshootMsg.txt")
			);
		}

		auto dbConn = dbHelperOpenDB();

		stLogInfo("Preloading db cache...");
		rebuildDBCache!UserDBOTypes(dbConn);

		if(clearSessions)
		{
			stLogInfo("Clearing persistent sessions...");
			SessionDB.dbDeleteAll(dbConn);
			return 0;
		}

		stLogInfo("Restoring sessions...");
		sessionStore = new MemorySessionStore();
		restoreSessions!CustomSession(dbConn);
	}
	
	stLogInfo("Initing HTTP server settings...");
	alias handlerDispatchError!CustomHandler customHandlerDispatchError;
	auto httpServerSettings = new HTTPServerSettings();
	httpServerSettings.port = port;
	httpServerSettings.bindAddresses = bindAddresses;
	httpServerSettings.sessionStore = sessionStore;
	httpServerSettings.errorPageHandler =
		(req, res, err) => customHandlerDispatchError!"errorHandler"(req, res, err);
	
	stLogInfo("Initing URL router...");
	auto router = initRouter!CustomHandler();
	
	if(customPostInit !is null)
	{
		stLogInfo("Running customPostInit...");
		if(auto errlvl = customPostInit(httpServerSettings, router) != -1)
			return errlvl;
	}
	
	stLogInfo("Forcing GC cycle...");
	GC.collect();
	GC.minimize();

	stLogInfo("Done initing SemiTwist Web Framework");
	listenHTTP(httpServerSettings, router);
	return -1;
}

private URLRouter initRouter(CustomHandler)()
{
	auto router = new URLRouter();

	foreach(pageName; PageBase.getNames())
		router.addPage( PageBase.get(pageName) );
	
	/// If you're serving the static files directly (for example, through a
	/// reverse proxy), you can prevent this application from serving them
	/// with --no-static
	if(!noStatic)
	{
		auto localPath = getExecPath ~ Conf.staticsRealPath;

		auto fss = new HTTPFileServerSettings();
		//fss.failIfNotFound   = true; // Setting isn't in latest vibe.d
		fss.serverPathPrefix = staticsUrl;

		if(noCacheStatic)
		{
			fss.maxAge           = seconds(1);
			fss.preWriteCallback = (scope req, scope res, ref physicalPath) {
				res.headers.remove("Etag");
				res.headers["Cache-Control"] = "no-store";
			};
		}
		else
			fss.maxAge = hours(24);
		
		router.get(staticsUrl~"*", serveStaticFiles(localPath, fss));
	}

	alias handlerDispatch!CustomHandler customHandlerDispatch;
	router.get ("*", &customHandlerDispatch!"notFound");
	router.post("*", &customHandlerDispatch!"notFound");
	
	return router;
}
