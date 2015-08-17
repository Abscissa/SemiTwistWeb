/// Copies 'res' and 'www-static' directories to your project.
/// Does NOT overwrite any files that already exist.

import std.algorithm;
import std.exception;
import std.file;
import std.path;
import std.range;
import std.stdio;

int main(string[] args)
{
	if(args.length != 3)
	{
		stderr.writeln("Usage: rdmd copyResources.d /path/to/your/project /path/to/SemiTwistWeb");
		return 1;
	}
	
	auto userPath         = buildNormalizedPath(args[1]) ~ dirSeparator;
	auto semitwistWebPath = buildNormalizedPath(args[2]) ~ dirSeparator;
	
	void doCopy(string srcPath)
	{
		enforce(srcPath.startsWith(semitwistWebPath));
		
		auto relativePath = srcPath[semitwistWebPath.length .. $];
		auto targetPath = buildNormalizedPath(userPath, relativePath);
		
		/+
		if(srcPath.isDir())
			write("DIR:  ");
		else
			write("FILE: ");

		writeln(srcPath, " \t -> ", targetPath);
		+/
		
		if(!targetPath.exists())
		{
			if(srcPath.isDir())
				mkdir(targetPath);
			else
				copy(srcPath, targetPath);
		}
	}

	auto semitwistWebResPath       = buildNormalizedPath(semitwistWebPath, "res"       ) ~ dirSeparator;
	auto semitwistWebWwwStaticPath = buildNormalizedPath(semitwistWebPath, "www-static") ~ dirSeparator;
	auto allDirEntries = chain(
		dirEntries(semitwistWebResPath,       SpanMode.breadth),
		dirEntries(semitwistWebWwwStaticPath, SpanMode.breadth),
	);

	doCopy(semitwistWebResPath);
	doCopy(semitwistWebWwwStaticPath);
	foreach(string srcPath; allDirEntries)
		doCopy(srcPath);
	
	return 0;
}
