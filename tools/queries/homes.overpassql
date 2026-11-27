[out:json][timeout:600];
area(id:3600913110)->.hk;
rel(area.hk)["boundary"="administrative"]["admin_level"="6"];
foreach -> .d (
  .d out tags;
  .d map_to_area -> .a;
  way(area.a)["building"~"^(apartments|residential|house|dormitory)$"];
  out center tags;
);
