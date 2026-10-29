"""Independent UEFI GPT 1.0 test metadata. No real disk is accessed."""
import hashlib,json,pathlib,struct,uuid,zlib
root=pathlib.Path(__file__).parent
manifest=[]
for sector in [512,4096]:
 total=4096;count=128;entry_size=128;table_sectors=(count*entry_size+sector-1)//sector
 first=2+table_sectors;backup_lba=total-1-table_sectors;last=backup_lba-1
 entries=bytearray(count*entry_size)
 names=['boot_a','persist','资料']
 for i,name in enumerate(names):
  start=first+64*i;end=start+31
  entry=uuid.UUID('49a4d17f-93a3-45c1-a0de-f50b2ebe2599').bytes_le+uuid.UUID(int=i+1).bytes_le+struct.pack('<QQQ',start,end,0)+name.encode('utf-16le').ljust(72,b'\0')
  entries[i*128:(i+1)*128]=entry
 crc=zlib.crc32(entries);disk=uuid.UUID('12345678-9abc-def0-1122-334455667788').bytes_le
 def header(current,alternate,entry_lba):
  data=bytearray(sector);data[:92]=struct.pack('<8sIIIIQQQQ16sQIII',b'EFI PART',0x10000,92,0,0,current,alternate,first,last,disk,entry_lba,count,entry_size,crc)
  struct.pack_into('<I',data,16,zlib.crc32(data[:92]));return data
 main=bytearray((2+table_sectors)*sector);main[510:512]=b'\x55\xaa';main[sector:2*sector]=header(1,total-1,2);main[2*sector:2*sector+len(entries)]=entries
 backup=bytearray((table_sectors+1)*sector);backup[:len(entries)]=entries;backup[table_sectors*sector:]=header(total-1,1,backup_lba)
 for kind,data in [('main',main),('backup',backup)]: (root/f'TEST_ONLY_gpt{sector}_{kind}.bin').write_bytes(data)
 manifest.append(dict(sector_size=sector,total_sectors=total,first_usable=first,last_usable=last,backup_start=backup_lba,names=names,sha256_main=hashlib.sha256(main).hexdigest(),sha256_backup=hashlib.sha256(backup).hexdigest()))
(root/'gpt_manifest.json').write_text(json.dumps({'reference':'https://uefi.org/specs/UEFI/2.11/05_GUID_Partition_Table_Format.html','fixtures':manifest},ensure_ascii=False,indent=2)+'\n')
print('Generated 512 / 4096-byte sector GPT metadata with independent Python zlib CRCs')
