/// Written in the D programming language.

module semitwistWeb.db;

import std.array;
import std.conv;
import std.datetime;
import std.digest.sha;
import std.exception;
import std.regex;
import std.string;
import std.traits;
import std.typecons;
import std.typetuple;

import vibe.vibe;
import vibe.core.connectionpool;

import mysql.db;
import semitwist.util.all;
import semitwistWeb.conf;
import semitwistWeb.util;

bool dbHelperLogSql;
LockedConnection!Connection delegate() dbHelperOpenDB;

private void ensureOpenDBIsSet()
{
	if(dbHelperOpenDB is null)
		throw new Exception("dbHelperOpenDB has not been set.");
}

string mySqlString()(string str)
{
	if(str is null)
		return "NULL";

	return "'" ~ str
		.replace(`\`,  `\\`)
		.replace("\0", `\0`)
		.replace("'",  `\'`)
		.replace("\b", `\b`)
		.replace("\n", `\n`)
		.replace("\r", `\r`)
		.replace("\t", `\t`)
		.replace("\x1A", `\Z`) ~ "'";
}

string mySqlString(T)(Nullable!T value)
{
	return value.isNull? "NULL" : mySqlString(value.get());
}

string mySqlString(T)(T value) if(isNumeric!T)
{
	return to!string(value);
}

// Template param needed to work around DMD Issue #16484
string mySqlString(T)(T dateTime) if(is(T==DateTime))
{
	return mySqlString( mySqlDateTime(dateTime) );
}

string mySqlDateTime(DateTime dateTime)
{
	return
		"%#.4d-%#.2d-%#.2d %#.2d:%#.2d:%#.2d".format(
			dateTime.year, dateTime.month, dateTime.day,
			dateTime.hour, dateTime.minute, dateTime.second
		);
}

T getNullable(T)(Row row, size_t index) if(isSomeString!T)
{
	if(row.isNull(index))
		return null;

	return row[index].coerce!T();
}

Nullable!T getNullable(T)(Row row, size_t index) if(is(T==DateTime))
{
	if(row.isNull(index))
		return Nullable!T();

	return Nullable!T( row[index].get!T() );
}

Nullable!T getNullable(T)(Row row, size_t index) if(!isSomeString!T && !is(T==DateTime))
{
	if(row.isNull(index))
		return Nullable!T();

	return Nullable!T( row[index].coerce!T() );
}

/// Runs 'res/init.sql' on the DB.
/// Ie, Completely clears the DB and creates the needed tables.
void initializeDB()
{
	int port = Conf.dbPort; // WhyTF was this needed?
	stLogInfo(
		format(
			"Initializing MySQL DB at %s:%s '%s', user '%s'...",
			Conf.dbHost, port, Conf.dbName, Conf.dbUser
		)
	);

	scope(failure)
	{
		stLogError(
			"There was an error initializing the database.\n",
			import("dbTroubleshootMsg.txt")
		);
	}

	auto dbConn = dbHelperOpenDB();
	auto db = Command(dbConn);

	auto sqlInitScript = import("init.sql");
	auto sqlInitStatements = sqlInitScript.split(";");
	foreach(sql; sqlInitStatements)
	{
		sql = sql.strip();
		if(sql != "")
		{
			db.sql = sql;
			db.runSQL();
		}
	}

	stLogInfo("Initializing DB done.");
}

string[uint] getDBColumns(Connection dbConn, string dbName, string tableName)
{
	auto db = Command(dbConn);
	db.sql = text(
		"SELECT `COLUMN_NAME`, `ORDINAL_POSITION` FROM `INFORMATION_SCHEMA`.`COLUMNS` WHERE",
		" `TABLE_SCHEMA`=", mySqlString(dbName), " AND `TABLE_NAME`=", mySqlString(tableName)
	);
	auto rows = db.execSQLResult();

	string[uint] result;
	foreach(row; rows)
		result[row[1/+"ORDINAL_POSITION"+/].coerce!uint()] = row[0/+"COLUMN_NAME"+/].toString();
	
	return result;
}

string[] getDBKeys(Connection dbConn, string dbName, string tableName)
{
	auto db = Command(dbConn);
	db.sql = text(
		"SELECT `COLUMN_NAME` FROM `INFORMATION_SCHEMA`.`KEY_COLUMN_USAGE` WHERE",
		" `TABLE_SCHEMA`=", mySqlString(dbName), " AND `TABLE_NAME`=", mySqlString(tableName)
	);
	auto rows = db.execSQLResult();

	string[] result;
	result.length = rows.length;
	size_t i=0;
	foreach(row; rows)
	{
		result[i] = row[0/+"COLUMN_NAME"+/].toString();
		i++;
	}
	
	return result;
}

bool runSQL(Connection dbConn, string sql)
{
	auto db = Command(dbConn);
	db.sql = sql;
	return db.runSQL();
}

bool runSQL(Connection dbConn, ref ulong rowsAffected, string sql)
{
	auto db = Command(dbConn);
	db.sql = sql;
	return db.runSQL(rowsAffected);
}

bool runSQL(ref Command db)
{
	ulong rowsAffected;
	return runSQL(db, rowsAffected);
}

bool runSQL(ref Command db, ref ulong rowsAffected)
{
	if(dbHelperLogSql)
		stLogInfo("runSQL: ", db.sql);

	return db.execSQL(rowsAffected);
}

bool dboRunSQL(T)(Connection dbConn, T dbo, string sql)
{
	auto db = Command(dbConn);
	db.sql = sql;
	return db.dboRunSQL(dbo);
}

bool dboRunSQL(T)(Connection dbConn, T dbo, ref ulong rowsAffected, string sql)
{
	auto db = Command(dbConn);
	db.sql = sql;
	return db.dboRunSQL(dbo, rowsAffected);
}

bool dboRunSQL(T)(ref Command db, T dbo)
{
	ulong rowsAffected;
	return dboRunSQL(db, dbo, rowsAffected);
}

bool dboRunSQL(T)(ref Command db, T dbo, ref ulong rowsAffected)
{
	if(dbHelperLogSql)
		stLogInfo("dboRunSQL: ", db.sql);

	ensureOpenDBIsSet();

	try
		return db.execSQL(rowsAffected);
	catch(MySQLReceivedException e)
		convertMySQLToDBO(e, dbo);
	assert(0);
}

ResultSet dboRunSQLResult(T)(ref Command db, T dbo, ColumnSpecialization[] csa = null)
{
	if(dbHelperLogSql)
		stLogInfo("dboRunSQLResult: ", db.sql);

	ensureOpenDBIsSet();

	try
		return db.execSQLResult(csa);
	catch(MySQLReceivedException e)
		convertMySQLToDBO(e, dbo);
	assert(0);
}

void convertMySQLToDBO(TDbo)(MySQLReceivedException e, TDbo dbo)
{
	//TODO: Add enums for error codes to mysql client driver
	if(e.errorCode == 1062)
		throw DBODuplicateEntryException.fromDBO(dbo, e);
	else
		throw e;
}

class DBOException : Exception
{
	this(string msg) { super(msg); }
}

class DBODuplicateEntryException : DBOException
{
	TypeInfo type;
	string fieldName;
	MySQLReceivedException mySqlException;
	
	this(TypeInfo type, string fieldName, MySQLReceivedException e)
	{
		this.type = type;
		this.fieldName = fieldName;
		this.mySqlException = e;

		string fieldMsg = fieldName==""? "{unknown}" : fieldName;
		super(text("Duplicate entry in column '", fieldMsg, "' for '", type, "'"));
	}
	
	static typeof(this) fromDBO(T)(T dbo, MySQLReceivedException e)
	{
		ensureOpenDBIsSet();
		
		enum logPrefix = typeof(this).stringof ~ ".fromDBO: ";

		// Try to parse key #
		string field = null;
		auto m = match(e.msg, regex(`key ([0-9]+)`));
		if(m && m.captures.length >= 2 && isNumeric(m.captures[1]))
		{
			uint keyNum;
			auto toUIntException = collectException!ConvException(to!uint(m.captures[1]), keyNum);
			if(!toUIntException)
			{
				auto keyIndex = keyNum-1;
				auto dbKeys = T.dbo.dbKeys(dbHelperOpenDB);
				if(keyIndex < dbKeys.length)
					field = dbKeys[keyIndex];
				else
				{
					stLogWarn(
						logPrefix,
						"Parsed key index ", keyIndex,
						", but metadata contains only ", dbKeys.length,
						" key(s)."/+, " Rebuilding DB cache."+/,
					);
					//rebuildDBCache(dbHelperOpenDB); // Can't do this, don't know the user's DBOs
				}
			}
		}
		
		if(field == "")
		{
			// Try to parse key name
			m = match(e.msg, regex(`key '([^']+)'`));
			if(m && m.captures.length >= 2)
			{
				string keyName = m.captures[1];
				auto dbKeys = T.dbo.dbKeys(dbHelperOpenDB);
				foreach(k,v; dbKeys)
				if(v == keyName)
				{
					field = keyName;
					break;
				}
				
				if(field == "")
				{
					stLogWarn(
						logPrefix,
						"Parsed key name '", keyName,
						"', but couldn't find such a key name in the metadata (",
						dbKeys, ")."/+, " Rebuilding DB cache."+/,
					);
					//rebuildDBCache(dbHelperOpenDB); // Can't do this, don't know the user's DBOs
				}
			}
		}

		if(field == "")
			stLogWarn(
				logPrefix, "Couldn't parse field name in MySQL server's error message: ",
				e.msg
			);

		return new typeof(this)(typeid(T), field, e);
	}
}

alias TypeTuple!(
	SessionDB,
	Token,
) DBOHelperTypes;

void clearDBCache(UserDBOTypes...)()
{
	foreach(T; TypeTuple!(UserDBOTypes, DBOHelperTypes))
		T.dbo.clearDBCache();
}

void fillDBCache(UserDBOTypes...)(Connection dbConn)
{
	foreach(T; TypeTuple!(UserDBOTypes, DBOHelperTypes))
		T.dbo.fillDBCache(dbConn);
}

void rebuildDBCache(UserDBOTypes...)(Connection dbConn)
{
	foreach(T; TypeTuple!(UserDBOTypes, DBOHelperTypes))
		T.dbo.rebuildDBCache(dbConn);
}

//TODO: Make dbName and dbTable runtime values, maybe as a defineDynamicDBO if necessary
mixin template defineDBO(alias dbTable)
{
	private static DBO _dbo;
	static @property DBO dbo()
	{
		if(_dbo is null)
		{
			//throw new Exception("dbo is null");
			_dbo = new DBO(dbTable);
		}
		
		return _dbo;
	}
}

final class DBO
{
	this(string dbTable, string dbName=null)
	{
		if(dbName == "")
			dbName = Conf.dbName;

		this._dbName = dbName;
		this._dbTable = dbTable;
	}
	
	private string _dbName;
	private string _dbTable;
	@property string dbName() { return _dbName; }
	@property string dbTable() { return _dbTable; }

	/**
	Metadata
	
	Note:
	To avoid possibility of race conditions (after all, this DOES do
	potentially fiber-switching IO), the members dbColumns and dbKeys
	are not built in-place, but rather built and *then* set atomically.
	
	It's OK if multiple fibers try to rebuild them simultaneously,
	because both fiber's results will be the same.

	WARNING!
	If you do IO or otherwise yield to another fiber, the values for dbColumns
	and dbKeys could change or become null. Therefore, you should always copy
	these to a local reference once and use that, instead of directly accessing
	these multiple times in the same loop/function/operation/etc. Ie:
	
	GOOD:
	auto columns = MyDBObject.dbo.dbColumns();
	if(5 in columns)
		return columns[5];
	
	BAD:
	if(5 in MyDBObject.dbo.dbColumns())
		return MyDBObject.dbo.dbColumns()[5];
	*/
	private string[uint] _dbColumns;
	string[uint] dbColumns(LockedConnection!Connection delegate() openDB) /// ditto
	{
		if(!_dbColumns)
		{
			auto dbConn = openDB();
			return dbColumns(dbConn);
		}
		
		return dbColumns(cast(Connection)null);
	}
	string[uint] dbColumns(Connection dbConn) /// ditto
	{
		if(!_dbColumns)
			_dbColumns = getDBColumns(dbConn, dbName, dbTable);
		
		return _dbColumns;
	}

	private string[] _dbKeys; /// ditto
	string[] dbKeys(LockedConnection!Connection delegate() openDB) /// ditto
	{
		if(!_dbKeys)
		{
			auto dbConn = openDB();
			return dbKeys(dbConn);
		}

		return dbKeys(cast(Connection)null);
	}
	string[] dbKeys(Connection dbConn) /// ditto
	{
		if(!_dbKeys)
			_dbKeys = getDBKeys(dbConn, dbName, dbTable);
		
		return _dbKeys;
	}
	
	// Cache control
	void clearDBCache()
	{
		_dbColumns = null;
		_dbKeys = null;
	}
	
	void fillDBCache(LockedConnection!Connection delegate() openDB)
	{
		if(!_dbColumns || !_dbKeys)
		{
			auto dbConn = openDB();
			fillDBCache(dbConn);
		}
		
		fillDBCache(cast(Connection)null);
	}

	void fillDBCache(Connection dbConn)
	{
		auto c = dbColumns(dbConn);
		auto k = dbKeys(dbConn);
	}
	
	void rebuildDBCache(LockedConnection!Connection delegate() openDB)
	{
		if(!_dbColumns || !_dbKeys)
		{
			auto dbConn = openDB();
			rebuildDBCache(dbConn);
		}
		
		rebuildDBCache(cast(Connection)null);
	}

	void rebuildDBCache(Connection dbConn)
	{
		clearDBCache();
		fillDBCache(dbConn);
	}
}

struct SessionDB
{
	string id;
	string userId;
	
	mixin defineDBO!("session");
	
	void dbInsert(Connection dbConn)
	{
		auto db = Command(dbConn);
		db.sql = text(
			"INSERT INTO `", dbo.dbTable, "` (",
			"`id`, `userId`",
			") VALUES (",
			mySqlString(id), ", ", mySqlString(userId),
			")"
		);
		db.dboRunSQL(this);
	}
	
	void dbDelete(Connection dbConn)
	{
		auto db = Command(dbConn);
		db.sql = text("DELETE IGNORE FROM `", dbo.dbTable, "` WHERE `id` = ", mySqlString(id));
		db.dboRunSQL(this);
	}
	
	static void dbDeleteAll(Connection dbConn)
	{
		auto db = Command(dbConn);
		db.sql = text("DELETE FROM `", dbo.dbTable, "`");
		db.dboRunSQL(SessionDB());
	}
	
	static SessionDB[] getAll(Connection dbConn)
	{
		SessionDB[] sessions;
		
		auto db = Command(dbConn);
		db.sql = text("SELECT `id`, `userId` FROM `", dbo.dbTable, "`");
		auto rows = db.dboRunSQLResult(SessionDB());
		if(rows.length == 0)
			return sessions;
		
		foreach(row; rows)
		{
			SessionDB sess;
			sess.id     = row[0/+"id"+/    ].toString();
			sess.userId = row[1/+"userId"+/].toString();
			sessions ~= sess;
		}
		
		return sessions;
	}
}

struct Token
{
	string type;
	string code;
	string email;
	DateTime expiration;
	ulong linkedId;
	
	mixin defineDBO!("token");
	
	void dbInsert(Connection dbConn)
	{
		auto db = Command(dbConn);
		db.sql = text(
			"INSERT INTO `", dbo.dbTable, "` (",
			"`type`, `code`, `expiration`, `email`, `linkedId`",
			") VALUES (",
			mySqlString(type), ", ", mySqlString(code), ", ", mySqlString(expiration), ", ",
			mySqlString(email), ", ", linkedId,
			")"
		);
		db.dboRunSQL(this);
	}
	
	void dbDelete(Connection dbConn)
	{
		auto db = Command(dbConn);
		db.sql = text(
			"DELETE FROM `", dbo.dbTable, "` WHERE `email`=", mySqlString(email),
			" AND `type`=", mySqlString(type), " AND `code`=", mySqlString(code)
		);
		db.dboRunSQL(this);
	}

	static Nullable!Token validate(Connection dbConn, string type, string code, string email)
	{
		Nullable!Token ret;
		auto db = Command(dbConn);
		db.sql = text(
			"SELECT `expiration`, `linkedId` FROM `"~dbo.dbTable~"`"~
			" WHERE `email`="~mySqlString(email)~
			" AND `type`="~mySqlString(type)~
			" AND `code`="~mySqlString(code)~
			" AND `expiration` >= NOW()"
		);
		auto rows = db.dboRunSQLResult(Token());
		if(rows.length == 0)
			return ret;
		
		Token token;
		token.type  = type;
		token.code  = code;
		token.email = email;
		token.expiration = rows[0][0/+"expiration"+/].get!DateTime();
		token.linkedId   = rows[0][1/+"linkedId"+/].coerce!ulong();
		
		ret = token;
		return ret;
	}
	
	//TODO*: Redo to use more chars so code is shorter. Also, skip the emailHash
	//       because making the same chars totally random is mathematically better anyway.
	//       In other words, this is temporarily crap and needs re-done.
	private static string genCode(string email)
	{
		auto emailHash = sha1Of(email);
		auto rnd = randomBytes(16);
		
		auto combined =
			(ubyte[]).init ~
			rnd[0] ~ emailHash[10] ~
			rnd[1] ~ emailHash[11] ~
			rnd[2] ~ emailHash[12] ~
			rnd[3] ~ emailHash[13] ~
			rnd[4] ~ emailHash[14] ~
			rnd[5] ~ emailHash[15] ~
			rnd[6] ~ emailHash[16] ~
			rnd[7] ~ emailHash[17] ~
			rnd[8..$];

		import semitwist.util.text : semitwistToHexString = toHexString;
		auto codeRaw = semitwistToHexString(combined);
		auto code = insertDashes(codeRaw);
		return code;
	}
	
	static Token create(
		Connection dbConn, string type, Duration lifetime,
		string email, ulong linkedId
	)
	{
		auto expiration = cast(DateTime)Clock.currTime() + lifetime;
		auto token = Token(type, "", email, expiration, linkedId);
		foreach(i; 0..20)
		{
			token.code = genCode(token.email);
			
			try
				token.dbInsert(dbConn);
			catch(DBODuplicateEntryException e)
			{
				if(e.fieldName == "code")
					continue; // Try generating another code

				throw e;
			}
			
			// Token was successfully inserted into DB
			return token;
		}
		
		// Failed to generate ununsed code
		throw new Exception("Unable to generate unique '"~type~"' token");
	}
}
