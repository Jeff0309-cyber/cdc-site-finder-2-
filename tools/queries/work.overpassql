[out:json][timeout:240];
area(id:3600913110)->.hk;
nwr(area.hk)["building"~"^(office|commercial)$"]; out center tags; nwr(area.hk)["office"]; out center; node(area.hk)["shop"]; out skel;
