/// Written in the D programming language.

module semitwistWeb.db;

import std.array;
import std.conv;
import std.datetime;
import std.digest.sha;
import std.exception;
import std.regex;
import std.string;
import std.typecons;
import std.typetuple;

import vibe.vibe;

import mysql.db;
import semitwist.util.all;
import semitwistWeb.util;

bool dbHelperLogSql;
Connection delegate() dbHelperOpenDB;

private void ensureOpenDBIsSet()
{
	if(dbHelperOpenDB is null)
		throw new Exception("dbHelperOpenDB has not been set.");
}

string mySqlString(string str)
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

string mySqlString(DateTime dateTime)
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

/// Runs 'res/init.sql' on the DB.
/// Ie, Completely clears the DB and creates the needed tables.
void initializeDB()
{
	int port = Conf.dbPort; // WhyTF is this needed?
	logInfo(
		"Initializing MySQL DB at %s:%s '%s', user '%s'...",
		Conf.dbHost, port, Conf.dbName, Conf.dbUser
	);

	scope(failure)
	{
		logError(
			"There was an error initializing the database.\n" ~
			import("dbTroubleshootMsg.txt")
		);
	}

	auto dbConn = dbHelperOpenDB();
	scope(exit) dbConn.close();
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

	logInfo("Initializing DB done.");
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
		logInfo("runSQL: "~db.sql);

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
		logInfo("dboRunSQL: "~db.sql);

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
		logInfo("dboRunSQLResult: "~db.sql);

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
		throw e; //TODO: Make sure this doesn't screw up the stack trace
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
				auto dbKeys = T.dbKeys(dbHelperOpenDB);
				if(keyIndex < dbKeys.length)
					field = dbKeys[keyIndex];
				else
				{
					logWarn(
						logPrefix~"Parsed key index %s, but metadata contains only %s key(s)."/+~" Rebuilding DB cache."+/,
						keyIndex, dbKeys.length
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
				auto dbKeys = T.dbKeys(dbHelperOpenDB);
				foreach(k,v; dbKeys)
				if(v == keyName)
				{
					field = keyName;
					break;
				}
				
				if(field == "")
				{
					logWarn(
						logPrefix~"Parsed key name '%s', but couldn't find such a key name in the metadata (%s)."/+~" Rebuilding DB cache."+/,
						keyName, dbKeys
					);
					//rebuildDBCache(dbHelperOpenDB); // Can't do this, don't know the user's DBOs
				}
			}
		}

		if(field == "")
			logWarn(
				logPrefix~"Couldn't parse field name in MySQL server's error message: %s",
				e.msg
			);

		return new typeof(this)(typeid(T), field, e);
	}
}

alias TypeTuple!(
	SessionDB,
) DBOHelperTypes;

void clearDBCache(UserDBOTypes...)()
{
	foreach(T; TypeTuple!(UserDBOTypes, DBOHelperTypes))
		T.clearDBCache();
}

void fillDBCache(UserDBOTypes...)(Connection dbConn)
{
	foreach(T; TypeTuple!(UserDBOTypes, DBOHelperTypes))
		T.fillDBCache(dbConn);
}

void rebuildDBCache(UserDBOTypes...)(Connection dbConn)
{
	foreach(T; TypeTuple!(UserDBOTypes, DBOHelperTypes))
		T.rebuildDBCache(dbConn);
}

//TODO: Make dbName and dbTable runtime values, maybe as a defineDynamicDBO if necessary
mixin template defineDBO(string _dbName, string _dbTable)
{
	static enum dbName  = _dbName;
	static enum dbTable = _dbTable;

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
	auto columns = MyDBObject.dbColumns();
	if(5 in columns)
		return columns[5];
	
	BAD:
	if(5 in MyDBObject.dbColumns())
		return MyDBObject.dbColumns()[5];
	*/
	private static string[uint] _dbColumns;
	static string[uint] dbColumns(Connection delegate() openDB) /// ditto
	{
		if(!_dbColumns)
		{
			auto dbConn = openDB();
			scope(exit) dbConn.close();
			return dbColumns(dbConn);
		}
		
		return dbColumns(cast(Connection)null);
	}
	static string[uint] dbColumns(Connection dbConn) /// ditto
	{
		if(!_dbColumns)
			_dbColumns = getDBColumns(dbConn, dbName, dbTable);
		
		return _dbColumns;
	}

	private static string[] _dbKeys; /// ditto
	static string[] dbKeys(Connection delegate() openDB) /// ditto
	{
		if(!_dbKeys)
		{
			auto dbConn = openDB();
			scope(exit) dbConn.close();
			return dbKeys(dbConn);
		}

		return dbKeys(cast(Connection)null);
	}
	static string[] dbKeys(Connection dbConn) /// ditto
	{
		if(!_dbKeys)
			_dbKeys = getDBKeys(dbConn, dbName, dbTable);
		
		return _dbKeys;
	}
	
	// Cache control
	static void clearDBCache()
	{
		_dbColumns = null;
		_dbKeys = null;
	}
	
	static void fillDBCache(Connection delegate() openDB)
	{
		if(!_dbColumns || !_dbKeys)
		{
			auto dbConn = openDB();
			scope(exit) dbConn.close();
			fillDBCache(dbConn);
		}
		
		fillDBCache(cast(Connection)null);
	}

	static void fillDBCache(Connection dbConn)
	{
		auto c = dbColumns(dbConn);
		auto k = dbKeys(dbConn);
	}
	
	static void rebuildDBCache(Connection delegate() openDB)
	{
		if(!_dbColumns || !_dbKeys)
		{
			auto dbConn = openDB();
			scope(exit) dbConn.close();
			rebuildDBCache(dbConn);
		}
		
		rebuildDBCache(cast(Connection)null);
	}

	static void rebuildDBCache(Connection dbConn)
	{
		clearDBCache();
		fillDBCache(dbConn);
	}
}

struct SessionDB
{
	string id;
	string userId;
	
	mixin defineDBO!(Conf.dbName, "session");
	
	void dbInsert(Connection dbConn)
	{
		auto db = Command(dbConn);
		db.sql = text(
			"INSERT INTO `", dbTable, "` (",
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
		db.sql = text("DELETE IGNORE FROM `", dbTable, "` WHERE `id` = ", mySqlString(id));
		db.dboRunSQL(this);
	}
	
	static void dbDeleteAll(Connection dbConn)
	{
		auto db = Command(dbConn);
		db.sql = text("DELETE FROM `", dbTable, "`");
		db.dboRunSQL(SessionDB());
	}
	
	static SessionDB[] getAll(Connection dbConn)
	{
		SessionDB[] sessions;
		
		auto db = Command(dbConn);
		db.sql = text("SELECT `id`, `userId` FROM `", dbTable, "`");
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
