import std.file;
import std.getopt;
import std.path;
import std.process;
import std.stdio;

class Fail : Exception
{
	this(string msg) { super(msg); }
}

immutable externDir = "externals";
immutable msgPrefix = "fetchExternals: ";

bool useSystemWGet=true;
bool force=false;
bool quiet=false;
bool verbose=false;

int main(string[] args)
{
	bool help;
	getopt(
		args,
		std.getopt.config.caseSensitive,
		"help",    &help,
		"F|force", &force,
		"q|quiet", &quiet,
		"verbose", &verbose,
	);
	
	if(help)
	{
		writeln(
`SemiTwist Web Framework - Fetch Externals
Usage: fetchExternals [options]

Options:
--help        Show this help screen and exit
-F,--force    Delete externals that already exist, instead of skipping them
-q,--quiet    Quiet mode
--verbose     Verbose mode`
		);
		return 0;
	}
	
	if(quiet && verbose)
	{
		errorMsg("Error: Can't use both --quiet and --verbose");
		return 1;
	}
	
	try
		fetchAll();
	catch(Fail e)
	{
		errorMsg("Error: "~e.msg);
		return 1;
	}
	
	return 0;
}

// Fetch --------------------------

void fetchAll()
{
	ensureTool("git");
	
	// wget not actually used right now, so don't check for it
	//version(Windows)
	//	useSystemWGet = toolExists("wget");
	//else
	//	checkTool("wget");
	
	ensureNotFile(externDir);
	makeDir(externDir);

	sandboxFetch(&fetchMustache,        "Mustache-D",        externDir~"/mustache-d");
	sandboxFetch(&fetchVibeD,           "Vibe.d",            externDir~"/vibed");
	sandboxFetch(&fetchSemiTwistDTools, "SemiTwist D Tools", externDir~"/SemiTwistDTools");
	sandboxFetch(&fetchArsd,            "arsd",              externDir~"/arsd");
}

void sandboxFetch(void function(string) dg, string name, string path)
{
	if(!init(name, path))
		return;
	
	auto oldDir = getcwd();
	scope(exit) chdir(oldDir);
	
	infoMsg("Fetching "~name~"...");
	
	try
		dg(path);
	catch(Fail e)
		errorMsg("Failure fetching "~name~": "~e.msg);
}

void fetchMustache(string path)
{
	chdir(path);
	gitClone(
		"https://github.com/repeatedly/mustache-d.git",
		"30ff2ae2b119c613d8cb5d0e536fe89119dee7ab"
	);
}

void fetchVibeD(string path)
{
	chdir(path);
	gitClone(
		"https://github.com/rejectedsoftware/vibe.d.git",
		"v0.7.13"
	);
}

void fetchSemiTwistDTools(string path)
{
	chdir(path);
	gitClone(
		"https://bitbucket.org/Abscissa/semitwistdtools.git",
		"c278c4620638629faa396a2d29e4b5034abf874d"
	);
}

void fetchArsd(string path)
{
	chdir(path);
	gitClone(
		"https://github.com/adamdruppe/misc-stuff-including-D-programming-language-web-stuff.git",
		"cf071218321654e34704c563fed1c06080fda837"
	);
}

// Utils --------------------------

void verboseMsg(lazy string msg)
{
	if(verbose)
		infoMsg(msg);
}

void infoMsg(string msg)
{
	if(!quiet)
		writeln(msg);
}

void errorMsg(string msg)
{
	stderr.writeln(msgPrefix~msg);
}

string quote(string str)
{
	version(Windows)
		return `"`~str~`"`;
	else
		return `'`~str~`'`;
}

void ensureNotFile(string path)
{
	if(exists(path) && !isDir(path))
	{
		if(force)
		{
			infoMsg("Removing '"~path~"'");
			remove(path);
		}
		else
			throw new Fail("'"~path~"' is not a directory");
	}
}

void ensureNotExist(string path)
{
	if(exists(path))
	{
		if(force)
		{
			infoMsg("Removing '"~path~"'");
			version(Windows)
				system("rmdir /S /Q "~quote(path));
			else
				system("rm -rf "~quote(path));
		}
		else
			throw new Fail("'"~path~"' already exists");
	}
}

void makeDir(string path)
{
	if(!exists(path))
	{
		verboseMsg("Creating '"~path~"'");
		mkdirRecurse(path);
	}
}

bool init(string name, string path)
{
	try
	{
		ensureNotFile(path);
		ensureNotExist(path);
		makeDir(path);
	}
	catch(Fail e)
	{
		infoMsg("Skipping "~name~": "~e.msg);
		return false;
	}
	
	return true;
}

void run(string cmd)
{
	verboseMsg("Running: "~cmd);
	
	auto errlevel = system(cmd);
	if(errlevel != 0)
		throw new Fail("Command failed (from '"~getcwd()~"'): "~cmd);
}

void ensureTool(string cmd, string cmdArgs="--help")
{
	auto cmdLine = cmd~" "~cmdArgs;
	verboseMsg("Checking: "~cmdLine);

	try
		auto result = shell(cmdLine);
	catch(Exception e)
		throw new Fail("Problem running '"~cmd~"'. Please make sure it's correctly installed.");
}

bool toolExists(string cmd, string cmdArgs="--help")
{
	auto cmdLine = cmd~" "~cmdArgs;
	verboseMsg("Checking: "~cmdLine);

	try
		auto result = shell(cmdLine);
	catch(Exception e)
		return false;
	
	return true;
}

void gitClone(string repo, string ver=null)
{
	auto quietSwitch = verbose? "" : "-q ";
	run("git clone "~quietSwitch~quote(repo)~" .");
	if(ver != "")
		run("git checkout "~quietSwitch~"-B semitwist-web "~quote(ver));
}

void wget(string url)
{
	auto quietSwitch = quiet? "-nv " : "";
	auto wgetExe = useSystemWGet? "wget" : externDir~dirSeparator~"wget";
	run(quote(wgetExe) ~ quietSwitch ~ quote(url));
}
