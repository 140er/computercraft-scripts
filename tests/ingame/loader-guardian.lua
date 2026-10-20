while true do
  local h=assert(fs.open("heartbeat.json","w"))
  h.write(textutils.serializeJSON({at=os.epoch("utc"),id=os.getComputerID()})) h.close()
  sleep(.5)
end
