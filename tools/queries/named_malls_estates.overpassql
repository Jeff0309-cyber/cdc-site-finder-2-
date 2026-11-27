[out:json][timeout:170];
area(id:3600913110)->.hk;
(
  nwr["shop"="mall"](area.hk);
  nwr["landuse"="residential"]["name"](area.hk);
  nwr["place"~"neighbourhood|quarter|suburb"]["name"](area.hk);
);
out center tags;
