package com.pointverse.app;
final class BuildVersion{static String name(android.content.Context c){try{return c.getPackageManager().getPackageInfo(c.getPackageName(),0).versionName;}catch(Exception e){return "";}}}
