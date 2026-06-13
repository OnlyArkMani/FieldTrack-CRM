allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Old plugins (e.g. background_locator_2) predate AGP's mandatory `namespace`
// and only declare `package=` in their AndroidManifest.xml. AGP 8+ needs
// `namespace` set in build.gradle, so backfill it here from the manifest
// rather than patching files in the pub cache (which `flutter pub get` wipes).
subprojects {
    afterEvaluate {
        val androidExt = project.extensions.findByName("android") ?: return@afterEvaluate
        val getNamespace = androidExt.javaClass.methods.find { it.name == "getNamespace" && it.parameterCount == 0 }
        val currentNamespace = getNamespace?.invoke(androidExt) as? String
        if (currentNamespace.isNullOrEmpty()) {
            val manifestFile = project.file("src/main/AndroidManifest.xml")
            if (manifestFile.exists()) {
                val pkg = Regex("package=\"([^\"]+)\"").find(manifestFile.readText())?.groupValues?.get(1)
                if (!pkg.isNullOrEmpty()) {
                    val setNamespace = androidExt.javaClass.methods.find { it.name == "setNamespace" && it.parameterCount == 1 }
                    setNamespace?.invoke(androidExt, pkg)
                }
            }
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
