/// Written in the D programming language.

module semitwistWeb.init;

import std.getopt;
import std.stdio;
import core.memory;

import vibe.vibe;
import vibe.core.args;
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
//TODO*? Fix: Calls to Vibe.d's log*() funcs should always use at least: "%s"

alias int function(ref HttpServerSettings, ref UrlRouter) CustomPostInit;

// This is a modification of vibe.d's built-in main().
int semitwistWebMain(CustomSession, CustomHandler, UserDBOTypes...)
	(string[] args, CustomPostInit customPostInit, Connection delegate() openDB)
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

	logInfo("Running event loop...");
	try {
		return runEventLoop();
	} catch( Throwable th ){
		logError("Unhandled exception in event loop: %s", th.toString());
		return 1;
	}
}

/// Returns: -1 normally, or else errorlevel to exit with
private int processCustomCmdLine(ref string[] args)
{
	getOption("init-db",           &initDB,              "Init the DB and exit (THIS WILL DESTROY ALL DATA!)");
	getOption("clear-sessions",    &clearSessions,       "Upon startup, clear sessions in DB insetad of resuming them.");
	getOption("port",              &port,                "Port to bind.");
	string bindAddress;
	while(getOption("ip", &bindAddress, "IP address to bind. (Can be specified multiple times)"))
		bindAddresses ~= bindAddress;
	getOption("no-cache",          &BaseHandler.noCache, "Disable internal page caching. (Useful during development)");
	getOption("no-cache-static",   &noCacheStatic,       "Set HTTP headers on static files to disable caching. (Useful during development)");
	getOption("no-static",         &noStatic,            "Disable serving of static files.");
	getOption("log",               &logFile,             "Set logfile.");

	getOption("insecure",          &BaseHandler.allowInsecure,   "Allow non-HTTPS requests.");
	getOption("insecure-cookies",  &useInsecureCookies,          "Don't set SECURE attribute on session cookies.");
	getOption("public-debug-info", &BaseHandler.publicDebugInfo, "Display uncaught exceptions and stack traces to user. (Useful during development)");
	getOption("log-sql",           &dbHelperLogSql,              "Log all SQL statements executed. (Useful during development)");
	
	try
	{
		if(!finalizeCommandLineOptions())
			return 0;
	}
	catch(Exception e)
	{
		logError("Error processing command line: %s", e.msg);
		return 1;
	}
	
	if(bindAddresses.length == 0)
		bindAddresses = ["0.0.0.0", "::"];
	
	if(logFile != "")
		setLogFile(logFile, LogLevel.Info);
	
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
			logError("This was compiled with -version=RequireSecure, therefore the following flags are disabled: --insecure --insecure-cookies --public-debug-info");
			return 1;
		}
	}
	
	// Warn about --insecure-cookies
	if(useInsecureCookies)
		logWarn("Used --insecure-cookies: INSECURE cookies are ON! Session cookies will not use the Secure attribute!");

	// Warn about --insecure
	if(BaseHandler.allowInsecure)
		logWarn("Used --insecure: INSECURE mode is ON! HTTPS will NOT be forced!");

	// Warn about HTTP
	if(Conf.host.toLower().startsWith("http://"))
	{
		if(BaseHandler.allowInsecure)
			logWarn(
				"Non-relative URLs are set to HTTP, not HTTPS! "~
				"If you did not intend this, change Conf.host and recompile."
			);
		else
		{
			// Require --insecure for non-HTTPS
			logError(
				"Conf.host is HTTP instead of HTTPS. THIS IS NOT RECOMMENDED. "~
				"If you wish to allow this anyway, you must use the --insecure flag. "~
				"Note that this will cause non-relative application URLs to be HTTP instead of HTTPS."
			);
			return 1;
		}
	}
	
	{
		scope(failure)
		{
			logError(
				"There was an error building the basic pages.\n" ~
				import("dbTroubleshootMsg.txt")
			);
		}

		auto dbConn = dbHelperOpenDB();
		scope(exit) dbConn.close();

		logInfo("Preloading db cache...");
		rebuildDBCache!UserDBOTypes(dbConn);

		if(clearSessions)
		{
			logInfo("Clearing persistent sessions...");
			SessionDB.dbDeleteAll(dbConn);
			return 0;
		}

		logInfo("Restoring sessions...");
		sessionStore = new MemorySessionStore();
		restoreSessions!CustomSession(dbConn);
	}
	
	logInfo("Initing HTTP server settings...");
	alias handlerDispatchError!CustomHandler customHandlerDispatchError;
	auto httpServerSettings = new HttpServerSettings();
	httpServerSettings.port = port;
	httpServerSettings.bindAddresses = bindAddresses;
	httpServerSettings.sessionStore = sessionStore;
	httpServerSettings.errorPageHandler =
		(req, res, err) => customHandlerDispatchError!"errorHandler"(req, res, err);
	
	logInfo("Initing URL router...");
	auto router = initRouter!CustomHandler();
	
	if(customPostInit !is null)
	{
		logInfo("Running customPostInit...");
		if(auto errlvl = customPostInit(httpServerSettings, router) != -1)
			return errlvl;
	}
	
	logInfo("Forcing GC cycle...");
	GC.collect();
	GC.minimize();

	logInfo("Done initing SemiTwist Web Framework");
	listenHttp(httpServerSettings, router);
	return -1;
}

private UrlRouter initRouter(CustomHandler)()
{
	auto router = new UrlRouter();

	foreach(pageName; PageBase.getNames())
		router.addPage( PageBase.get(pageName) );
	
	/// If you're serving the static files directly (for example, through a
	/// reverse proxy), you can prevent this application from serving them
	/// with --no-static
	if(!noStatic)
	{
		auto localPath = getExecPath ~ Conf.staticsRealPath;

		auto fss = new HttpFileServerSettings();
		fss.failIfNotFound   = true;
		fss.serverPathPrefix = staticsUrl;

		if(noCacheStatic)
		{
			fss.maxAge           = seconds(1);
			fss.preWriteCallback = (req, res, ref physicalPath) {
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
