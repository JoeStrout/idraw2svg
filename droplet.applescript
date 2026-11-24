-- idraw2svg droplet: drop .idraw files (or folders of them) here to
-- convert each foo.idraw to foo.svg beside it.
-- Build with: ./make-droplet.sh

property miniscript : "/usr/local/bin/miniscript"
property converter : "~/svnrepo/idraw2svg/idraw2svg.ms"

on open droppedItems
	set args to ""
	repeat with f in droppedItems
		set args to args & " " & quoted form of POSIX path of f
	end repeat
	try
		set report to do shell script miniscript & " " & converter & args & " 2>&1; true"
		display dialog report buttons {"OK"} default button 1 with title "idraw2svg"
	on error errMsg
		display dialog errMsg buttons {"OK"} default button 1 with title "idraw2svg" with icon caution
	end try
end open

on run
	set picked to choose file with prompt "Choose Graphic (.idraw) files to convert to SVG:" with multiple selections allowed
	open picked
end run
