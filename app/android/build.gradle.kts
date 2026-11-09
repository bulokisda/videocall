allprojects {
    repositories {
        google()
        mavenCentral()
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


tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}


subprojects {
    afterEvaluate {
        if (plugins.hasPlugin("com.android.library") || plugins.hasPlugin("com.android.application")) {
            val androidExtension = extensions.findByName("android") as? com.android.build.gradle.BaseExtension
            if (androidExtension != null && androidExtension.namespace == null) {
                // 🟢 FIXED: Explicitly maps the plugin back to its true resource namespace 
                // so the generated 'R' class matches the hardcoded Kotlin imports.
                if (project.name == "flutter_callkit_incoming") {
                    androidExtension.namespace = "com.hiennv.flutter_callkit_incoming"
                } else {
                    androidExtension.namespace = group.toString()
                }
            }
        }
    }

    // Performs clean configuration-level stripping of legacy manifest attributes
    val manifestFile = file("src/main/AndroidManifest.xml")
    if (manifestFile.exists()) {
        try {
            var content = manifestFile.readText()
            if (content.contains("package=\"")) {
                content = content.replace(Regex("""package="[^"]+""""), "")
                manifestFile.writeText(content)
                logger.lifecycle("--> [Sanitizer] Cleaned manifest file for module: ${project.name}")
            }
        } catch (e: Exception) {
            logger.warn("--> [Sanitizer] Failed to patch manifest for ${project.name}: ${e.message}")
        }
    }
}



