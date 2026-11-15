/**
 * ChopPool weekly backup to Google Drive.
 * Paste this into a new project at script.google.com (signed in with the Google account that should keep the backups).
 * Then run "setup" once. It makes the backup key, the "ChopPool backups" folder and the weekly schedule.
 * Every Sunday at about 2 am it saves the whole database as a .json file and keeps the last 8 copies.
 * If a backup fails, or a table could not be read, you get an email.
 */
var FUNCTION_URL = "https://urdodbvwgujqrlqziain.supabase.co/functions/v1/backup";
var FOLDER_NAME = "ChopPool backups";
var KEEP = 8;

function setup() {
  var props = PropertiesService.getScriptProperties();
  var key = props.getProperty("BACKUP_KEY");
  if (!key) { key = Utilities.getUuid().replace(/-/g, "") + Utilities.getUuid().replace(/-/g, ""); props.setProperty("BACKUP_KEY", key); }
  folder_();
  ScriptApp.getProjectTriggers().forEach(function (t) { if (t.getHandlerFunction() === "runBackup") ScriptApp.deleteTrigger(t); });
  ScriptApp.newTrigger("runBackup").timeBased().everyWeeks(1).onWeekDay(ScriptApp.WeekDay.SUNDAY).atHour(2).create();
  Logger.log("Done. Copy this key into Supabase › Edge Functions › Secrets as BACKUP_KEY:\n\n" + key + "\n\nThen run runBackup once to test.");
}

function runBackup() {
  var key = PropertiesService.getScriptProperties().getProperty("BACKUP_KEY");
  if (!key) throw new Error("Run setup first.");
  var res, body, data;
  try {
    res = UrlFetchApp.fetch(FUNCTION_URL, { method: "post", headers: { "x-backup-key": key }, muteHttpExceptions: true });
    body = res.getContentText();
    if (res.getResponseCode() !== 200) throw new Error("The backup service answered " + res.getResponseCode() + ": " + body.slice(0, 300));
    data = JSON.parse(body);
    if (!data.tables || !data.counts) throw new Error("The backup came back empty.");
  } catch (e) {
    alert_("ChopPool backup failed", "This week's backup was not saved.\n\n" + e.message + "\n\nIf this says 401, the BACKUP_KEY in Supabase doesn't match this script.");
    throw e;
  }
  var day = Utilities.formatDate(new Date(), "Africa/Accra", "yyyy-MM-dd");
  var folder = folder_();
  folder.createFile(Utilities.newBlob(body, "application/json", "choppool-backup-" + day + ".json"));
  // Keep the newest copies only
  var files = [], it = folder.getFiles();
  while (it.hasNext()) { var f = it.next(); if (/^choppool-backup-.*\.json$/.test(f.getName())) files.push(f); }
  files.sort(function (a, b) { return b.getDateCreated() - a.getDateCreated(); });
  files.slice(KEEP).forEach(function (f) { f.setTrashed(true); });
  if (data.problems && data.problems.length) {
    alert_("ChopPool backup saved with gaps", "The backup was saved, but some data could not be read:\n\n" + data.problems.join("\n"));
  }
  var total = Object.keys(data.counts).reduce(function (s, k) { return s + data.counts[k]; }, 0);
  Logger.log("Saved choppool-backup-" + day + ".json: " + Object.keys(data.counts).length + " tables, " + total + " rows, " + data.accounts + " accounts.");
}

function folder_() {
  var it = DriveApp.getFoldersByName(FOLDER_NAME);
  return it.hasNext() ? it.next() : DriveApp.createFolder(FOLDER_NAME);
}

function alert_(subject, text) {
  MailApp.sendEmail(Session.getEffectiveUser().getEmail(), subject, text);
}
