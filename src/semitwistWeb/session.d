/// Written in the D programming language.

module semitwistWeb.session;

import std.conv;
import std.datetime;
import std.typecons;
import std.typetuple;
import std.variant;

import vibe.vibe;
import mysql.db;
import semitwist.util.all;

import semitwistWeb.conf;
import semitwistWeb.db;
import semitwistWeb.doc;
import semitwistWeb.util;

SessionStore sessionStore;
SessionData[string] sessions; // Indexed by session id

string _cookiePath;
@property string cookiePath()
{
	if(_cookiePath is null)
		_cookiePath = Conf.urlBase=="/"? "/" : Conf.urlBase[0..$-1];
	
	return _cookiePath;
}

bool useInsecureCookies = false;

enum LoginState
{
	Out, In
}

class SessionData
{
	// Static timeoutDuration
	private static bool initedTimeoutDuration = false;
	private static Duration _timeoutDuration;
	@property static Duration timeoutDuration()
	{
		if(!initedTimeoutDuration)
			timeoutDuration = minutes(30);
		
		return _timeoutDuration;
	}
	@property static void timeoutDuration(Duration value)
	{
		_timeoutDuration = value;
		initedTimeoutDuration = true;
	}

	// Main session data
	string   id;
	Session  session;
	DateTime lastAccess;  //TODO? Should this be SysTime?
	bool     isDummyLogin = false;
	string   oneShotMessage;
	string   postLoginUrl;  /// Empty string implies default
	
	/// The ID of the logged-in user, or null if logged out
	private string _userId;
	@property final string userId() /// ditto
	{
		return _userId;
	}

	@property final bool isLoggedIn()
	{
		return _userId !is null;
	}

	@property final LoginState loginState()
	{
		return isLoggedIn? LoginState.In : LoginState.Out;
	}

	// Instance methods
	this(string id)
	{
		this.id = id;
	}

	void login(Connection dbConn, string userId)
	{
		if(isLoggedIn)
			logout(dbConn);
		
		SessionDB(id, userId).dbInsert(dbConn);

		this._userId = userId;
		isDummyLogin = false;
	}
	
	/// Ugly hack to "login" with a dummy account, bypassing the DB.
	/// Needed by the document caching/preloading system.
	void dummyLogin()
	{
		this._userId = "{xxxxx}";
		isDummyLogin = true;
	}
	
	void logout(Connection dbConn)
	{
		if(!isLoggedIn)
			return;
		
		auto oldUserId = _userId;
		_userId = null;
		
		if(!isDummyLogin)
			SessionDB(id, oldUserId).dbDelete(dbConn);
	}
	
	final void keepAlive()
	{
		lastAccess = cast(DateTime) Clock.currTime();
	}
	
	/// Ends the session if it's timed out
	final void checkTimeout(HTTPServerRequest req, HTTPServerResponse res)
	{
		auto now = cast(DateTime) Clock.currTime();
		if(now - lastAccess > timeoutDuration)
		{
			{
				auto dbConn = dbHelperOpenDB();
				logout(dbConn);
			}

			sessions.remove(this.id);
			if(req !is null)
				req.session = Session();
			res.terminateSession();
		}
	}
	
	void restoreSession(Connection dbConn)
	{
		// Do nothing
	}
	
	static SessionData restore(TSession)(Connection dbConn, SessionDB dbSess)
	{
		// Restore basic info
		SessionData sess = new TSession(dbSess.id);
		sess._userId = dbSess.userId;
		sess.keepAlive();

		// Attach to Vibe.d session list
		sessionStore.set(dbSess.id, "__dummy__", Variant(""));
		auto vibeSess = sessionStore.open(dbSess.id);
		sess.session = vibeSess;
		sess.session.set("$sessionCookiePath", cookiePath);
		sess.session.set("$sessionCookieSecure", to!string(!useInsecureCookies));

		// Add to ADAMS session list
		sessions[dbSess.id] = sess;
		
		// Restore data
		sess.restoreSession(dbConn);
		
		return sess;
	}
}

void restoreSessions(TSession)(Connection dbConn)
{
	auto dbSessions = SessionDB.getAll(dbConn);
	foreach(dbSess; dbSessions)
		SessionData.restore!TSession(dbConn, dbSess);
}
