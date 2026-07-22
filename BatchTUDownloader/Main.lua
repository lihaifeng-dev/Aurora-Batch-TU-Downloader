scriptTitle = "Batch Title Update Downloader"
scriptAuthor = "Li Haifeng"
scriptVersion = 1.5
scriptDescription = "Batch-download the latest Title Update for every game in Aurora from XboxUnity."
scriptIcon = "icon.png"
scriptPermissions = { "http", "filesystem", "content", "sql" }

-- Batch edition by Li Haifeng. Based on the original TUDownloader by Swizzy & EccentricVamp.

local JSON = require("JSON");

-- Aurora's Http.Get may append unused buffer bytes after valid JSON.
-- Accept the valid leading JSON value, matching the original TUDownloader fix.
function JSON:onTrailingGarbage(json_text, location, parsed_value, etc)
	return parsed_value;
end

local API_BASE = "http://xboxunity.net/api";
local DOWNLOADS_REL = "Downloads\\";
local FAILURE_LOG_DIR = "Game:\\Data\\Logs\\";
local FAILURE_LOG_PATH = FAILURE_LOG_DIR .. "BatchTUDownloader_Failures.log";

local MODE_SKIP_EXISTING = 1;
local MODE_OVERWRITE = 2;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function FormatSize(bytes)
	bytes = tonumber(bytes) or 0;
	if bytes < 1024 then
		return string.format("%d B", bytes);
	elseif bytes < 1048576 then
		return string.format("%.1f KB", bytes / 1024);
	elseif bytes < 1073741824 then
		return string.format("%.1f MB", bytes / 1048576);
	end
	return string.format("%.1f GB", bytes / 1073741824);
end

local function SqlStr(value)
	return "'" .. tostring(value or ""):gsub("'", "''") .. "'";
end

-- Aurora stores DWORD values as signed 32-bit integers in SQLite.
local function Int32(value)
	local n = (tonumber(value) or 0) % 4294967296;
	if n >= 2147483648 then
		n = n - 4294967296;
	end
	return string.format("%d", n);
end

local function TitleHex(value)
	return string.format("%08X", tonumber(value) or 0);
end

local function LivePathFor(titleId, filename)
	if string.sub(tostring(filename or ""), 1, 3) == "TU_" then
		return "\\Cache\\";
	end
	return string.format("\\Content\\0000000000000000\\%08X\\000B0000\\", titleId);
end

local function HashesMatch(a, b)
	return a ~= nil and b ~= nil and string.lower(tostring(a)) == string.lower(tostring(b));
end

local function HttpJson(url)
	local ret = Http.Get(url);
	if ret == nil or ret.Success ~= true or ret.OutputData == nil then
		return nil, "HTTP request failed";
	end

	local ok, decoded = pcall(function()
		return JSON:decode(ret.OutputData);
	end);
	if not ok then
		return nil, "Invalid JSON response";
	end
	return decoded, nil;
end

local function FindHddDrive()
	local drives = FileSystem.GetDrives(true);
	if type(drives) ~= "table" then
		return nil;
	end

	-- Prefer Hdd1 explicitly.
	for _, drive in ipairs(drives) do
		local mount = string.lower(tostring(drive.MountPoint or ""));
		if mount == "hdd1" or mount == "hdd1:" then
			return drive;
		end
	end

	-- Fall back to the first internal HDD-like content drive.
	for _, drive in ipairs(drives) do
		local mount = string.lower(tostring(drive.MountPoint or ""));
		if string.sub(mount, 1, 3) == "hdd" then
			return drive;
		end
	end

	return nil;
end

local function BuildGamesList()
	local games = {};
	local seen = {};
	local collection = Content.FindContent();

	if type(collection) ~= "table" then
		return games;
	end

	for i = 1, #collection do
		local item = collection[i];
		if item.TitleId ~= nil and item.TitleId ~= 0 then
			local key = string.format("%08X_%08X", item.TitleId, item.BaseVersion or 0);
			if seen[key] == nil then
				seen[key] = true;
				table.insert(games, {
					Name = tostring(item.Name or TitleHex(item.TitleId)),
					TitleId = item.TitleId,
					MediaId = item.MediaId or 0,
					BaseVersion = item.BaseVersion or 0,
				});
			end
		end
	end

	table.sort(games, function(a, b)
		return string.lower(a.Name) < string.lower(b.Name);
	end);
	return games;
end

local function GetInstalledRows(game)
	local query = string.format(
		"SELECT Id, Hash, Version, BackupPath FROM TitleUpdates WHERE TitleId = %s AND BaseVersion = %s",
		Int32(game.TitleId), Int32(game.BaseVersion));
	local rows = Sql.ExecuteFetchRows(query);
	if type(rows) == "table" then
		return rows;
	end
	return {};
end

local function FindLatestTU(tus)
	if type(tus) ~= "table" then
		return nil;
	end

	local latest = nil;
	for _, tu in ipairs(tus) do
		if type(tu) == "table" then
			local version = tonumber(tu.version) or -1;
			local id = tonumber(tu.TitleUpdateID) or -1;
			if latest == nil
				or version > (tonumber(latest.version) or -1)
				or (version == (tonumber(latest.version) or -1)
					and id > (tonumber(latest.TitleUpdateID) or -1)) then
				latest = tu;
			end
		end
	end
	return latest;
end

local function ValidateTU(tu)
	if type(tu) ~= "table" then
		return false, "invalid TU data";
	end
	if tu.TitleUpdateID == nil then
		return false, "missing TitleUpdateID";
	end
	if tu.filename == nil or tostring(tu.filename) == "" then
		return false, "missing filename";
	end
	if tu.tuhash == nil or tostring(tu.tuhash) == "" then
		return false, "missing TU hash";
	end
	if tu.url == nil or tostring(tu.url) == "" then
		return false, "missing download URL";
	end
	return true, nil;
end

local function RegisterTitleUpdate(game, tu, drive, backupFile, livePath, overwrite)
	local exists = Sql.ExecuteFetchRows(string.format(
		"SELECT Id FROM TitleUpdates WHERE TitleId = %s AND Hash = %s AND LiveDeviceId = %s",
		Int32(game.TitleId), SqlStr(tu.tuhash), SqlStr(drive.Serial)));

	local alreadyRegistered = type(exists) == "table" and #exists > 0;
	if alreadyRegistered and overwrite then
		local rowId = tonumber(exists[1].Id);
		if rowId == nil then
			return false, "invalid existing database row";
		end

		local update = "UPDATE TitleUpdates SET "
			.. "FileName = " .. SqlStr(tu.filename) .. ", "
			.. "LivePath = " .. SqlStr(livePath) .. ", "
			.. "Version = " .. Int32(tu.version) .. ", "
			.. "BackupPath = " .. SqlStr(backupFile) .. ", "
			.. "BaseVersion = " .. Int32(game.BaseVersion) .. ", "
			.. "DisplayName = " .. SqlStr(game.Name) .. ", "
			.. "MediaId = " .. Int32(game.MediaId) .. ", "
			.. "FileSize = " .. SqlStr(FormatSize(tu.filesize))
			.. " WHERE Id = " .. string.format("%d", rowId);

		if Sql.Execute(update) ~= true then
			return false, "could not refresh Aurora database row";
		end
		return true, "refreshed";
	end

	if alreadyRegistered then
		return true, "already-registered";
	end

	local insert = "INSERT INTO TitleUpdates "
		.. "(FileName, LiveDeviceId, LivePath, TitleId, Version, Hash, BackupPath, BaseVersion, DisplayName, MediaId, FileSize) VALUES ("
		.. SqlStr(tu.filename) .. ", "
		.. SqlStr(drive.Serial) .. ", "
		.. SqlStr(livePath) .. ", "
		.. Int32(game.TitleId) .. ", "
		.. Int32(tu.version) .. ", "
		.. SqlStr(tu.tuhash) .. ", "
		.. SqlStr(backupFile) .. ", "
		.. Int32(game.BaseVersion) .. ", "
		.. SqlStr(game.Name) .. ", "
		.. Int32(game.MediaId) .. ", "
		.. SqlStr(FormatSize(tu.filesize)) .. ")";

	if Sql.Execute(insert) ~= true then
		return false, "could not add TU to Aurora database";
	end
	return true, "installed";
end

local function DownloadAndRegister(game, tu, drive, overwrite)
	local valid, validationError = ValidateTU(tu);
	if not valid then
		return false, validationError;
	end

	local meta, metaError = HttpJson(API_BASE .. "/tumd5/" .. tostring(tu.TitleUpdateID));
	if meta == nil or meta.md5 == nil then
		return false, metaError or "could not retrieve MD5";
	end

	local livePath = LivePathFor(game.TitleId, tu.filename);
	local backupDir = string.format(
		"Game:\\Data\\TitleUpdates\\%s\\%08X\\%s\\",
		tostring(drive.Serial), game.TitleId, tostring(tu.tuhash));
	local backupFile = backupDir .. tostring(tu.filename);

	FileSystem.CreateDirectory(backupDir);

	local existingValid = false;
	if FileSystem.FileExists(backupFile) then
		local existingMd5 = Aurora.Md5HashFile(backupFile);
		existingValid = HashesMatch(existingMd5, meta.md5);
	end

	-- Overwrite mode deliberately downloads again even when the current backup is valid.
	if overwrite or not existingValid then
		-- Use the exact filename returned by XboxUnity, matching the original
		-- TUDownloader. Prefixing or otherwise changing long TU filenames can
		-- cause path-handling problems on the console.
		local relPath = DOWNLOADS_REL .. tostring(tu.filename);
		local lastError = nil;
		local verifiedPath = nil;

		-- Retry once after completely clearing the temporary download folder.
		for attempt = 1, 2 do
			FileSystem.DeleteDirectory(Script.GetBasePath() .. DOWNLOADS_REL);
			Script.CreateDirectory("Downloads");

			local dl = Http.Get(tu.url, relPath);
			if dl == nil or dl.Success ~= true or dl.OutputPath == nil then
				lastError = string.format(
					"download failed (attempt %d/2, TU ID %s, file %s)",
					attempt, tostring(tu.TitleUpdateID), tostring(tu.filename));
			else
				local got = Aurora.Md5HashFile(dl.OutputPath);
				if HashesMatch(got, meta.md5) then
					verifiedPath = dl.OutputPath;
					break;
				end

				lastError = string.format(
					"MD5 verification failed (attempt %d/2, TU ID %s, file %s, got %s, expected %s)",
					attempt, tostring(tu.TitleUpdateID), tostring(tu.filename),
					tostring(got), tostring(meta.md5));
				print("BatchTU: " .. game.Name .. ": " .. lastError);
			end
		end

		if verifiedPath == nil then
			FileSystem.DeleteDirectory(Script.GetBasePath() .. DOWNLOADS_REL);
			return false, lastError or "download verification failed";
		end

		if FileSystem.MoveFile(verifiedPath, backupFile, true) ~= true then
			FileSystem.DeleteDirectory(Script.GetBasePath() .. DOWNLOADS_REL);
			return false, string.format(
				"could not save verified TU (TU ID %s, file %s)",
				tostring(tu.TitleUpdateID), tostring(tu.filename));
		end
		FileSystem.DeleteDirectory(Script.GetBasePath() .. DOWNLOADS_REL);
	end

	return RegisterTitleUpdate(game, tu, drive, backupFile, livePath, overwrite);
end

local function ModeName(mode)
	if mode == MODE_OVERWRITE then
		return "Overwrite / refresh latest";
	end
	return "Do not overwrite";
end

local function WriteFailureLog(stats, mode)
	if stats.failed <= 0 or #stats.failures == 0 then
		return true;
	end

	local lines = {
		"Batch Title Update Downloader - Failure Log",
		"===========================================",
		"Mode: " .. ModeName(mode),
		"Games found: " .. tostring(stats.total),
		"Installed/refreshed: " .. tostring(stats.installed),
		"Skipped existing: " .. tostring(stats.skippedExisting),
		"No TU on XboxUnity: " .. tostring(stats.noTU),
		"Failed: " .. tostring(stats.failed),
		"",
		"Failures:",
	};

	for index, failure in ipairs(stats.failures) do
		table.insert(lines, string.format("%d. %s", index, failure));
	end

	FileSystem.CreateDirectory(FAILURE_LOG_DIR);
	local content = table.concat(lines, "\r\n") .. "\r\n";
	return FileSystem.WriteFile(FAILURE_LOG_PATH, content) == true;
end

local function ChooseMode()
	local options = {
		"Do not overwrite - skip titles that already have a TU",
		"Overwrite - re-download the latest TU for every title",
	};
	local pick = Script.ShowPopupList(
		scriptTitle,
		"Choose how existing Title Updates should be handled",
		options);
	if pick.Canceled then
		return nil;
	end
	return pick.Selected.Key;
end

local function MakeSummary(stats, mode)
	local text = "Mode: " .. ModeName(mode) .. "\n\n";
	text = text .. "Games found: " .. tostring(stats.total) .. "\n";
	text = text .. "Installed/refreshed: " .. tostring(stats.installed) .. "\n";
	text = text .. "Skipped existing: " .. tostring(stats.skippedExisting) .. "\n";
	text = text .. "No TU on XboxUnity: " .. tostring(stats.noTU) .. "\n";
	text = text .. "Failed: " .. tostring(stats.failed) .. "\n";

	return text;
end

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

function main()
	if Aurora.HasInternetConnection() ~= true then
		Script.ShowMessageBox(
			"ERROR",
			"This script requires an active internet connection.",
			"OK");
		return;
	end

	local mode = ChooseMode();
	if mode == nil then
		return;
	end

	local drive = FindHddDrive();
	if drive == nil or drive.Serial == nil then
		Script.ShowMessageBox(
			"ERROR",
			"Hdd1 could not be found as a content-capable drive.",
			"OK");
		return;
	end

	local games = BuildGamesList();
	if #games == 0 then
		Script.ShowMessageBox(
			scriptTitle,
			"No installed games were found in Aurora's library.",
			"OK");
		return;
	end

	local stats = {
		total = #games,
		installed = 0,
		skippedExisting = 0,
		alreadyCurrent = 0,
		noTU = 0,
		failed = 0,
		failures = {},
	};

	print("-- " .. scriptTitle .. " Started --");
	print("Mode: " .. tostring(mode));
	print("Target drive: " .. tostring(drive.MountPoint) .. " / " .. tostring(drive.Serial));

	for index, game in ipairs(games) do
		local percent = math.floor(((index - 1) / #games) * 100);
		Script.SetProgress(percent);
		Script.SetStatus(string.format(
			"[%d/%d] Checking %s",
			index, #games, game.Name));

		local installedRows = GetInstalledRows(game);

		local listUrl = string.format(
			"%s/tu/%08X/%08X",
			API_BASE, game.TitleId, game.BaseVersion);

		local tus, apiError = HttpJson(listUrl);
		local latest = FindLatestTU(tus);

		if latest == nil then
			stats.noTU = stats.noTU + 1;
			print(string.format(
				"NO TU: %s [%s/%s] %s",
				game.Name, TitleHex(game.TitleId), TitleHex(game.BaseVersion),
				tostring(apiError or "")));
		else
			if mode == MODE_SKIP_EXISTING and #installedRows > 0 then
				stats.skippedExisting = stats.skippedExisting + 1;
				print(string.format(
					"SKIP existing: %s [%s/%s]",
					game.Name, TitleHex(game.TitleId), TitleHex(game.BaseVersion)));

			else
				Script.SetStatus(string.format(
					"[%d/%d] Downloading %s TU%s",
					index, #games, game.Name, tostring(latest.version)));

				local ok, result = DownloadAndRegister(
					game, latest, drive, mode == MODE_OVERWRITE);

				if ok then
					stats.installed = stats.installed + 1;
					print(string.format(
						"OK: %s TU%s (%s)",
						game.Name, tostring(latest.version), tostring(result)));
				else
					stats.failed = stats.failed + 1;

					local failure = string.format(
						"%s [%s]: %s",
						game.Name, TitleHex(game.TitleId), tostring(result));

					table.insert(stats.failures, failure);
					print("FAILED: " .. failure);
				end
			end
		end
	end

	FileSystem.DeleteDirectory(Script.GetBasePath() .. DOWNLOADS_REL);
	stats.failureLogWritten = true;
	if stats.failed > 0 then
		stats.failureLogWritten = WriteFailureLog(stats, mode);
		if stats.failureLogWritten then
			print("Failure log written: " .. FAILURE_LOG_PATH);
		else
			print("WARNING: Could not write failure log: " .. FAILURE_LOG_PATH);
		end
	end

	Script.SetProgress(100);
	Script.SetStatus("Finished");
	print("-- " .. scriptTitle .. " Finished --");

	local summary = MakeSummary(stats, mode);
	if stats.installed > 0 then
		local restart = Script.ShowMessageBox(
			"Batch TU download complete",
			summary .. "\nRestart Aurora to load downloaded TUs.",
			"Restart Aurora",
			"Later");
		if restart.Button == 1 then
			Aurora.Restart();
		end
	else
		Script.ShowMessageBox("Batch TU download complete", summary, "OK");
	end
end
