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
subprojects {
    project.evaluationDependsOn(":app")
}

// ⚠️ La carte (Mapbox, 2026-09-25) : son paquet n'applique le plugin Kotlin
// que sous AGP 8, et suppose au-delà le Kotlin intégré d'AGP 9 — que ce
// projet désactive (`android.builtInKotlin=false`, gabarit Flutter, gardé
// pour rive_native et flutter_foreground_task). Sans ce bloc, son bloc
// `kotlin {}` n'existe pas et la construction échoue. On lui applique le
// plugin, à lui seul, dès qu'il devient une bibliothèque Android.
subprojects {
    if (name == "mapbox_maps_flutter") {
        plugins.withId("com.android.library") {
            apply(plugin = "org.jetbrains.kotlin.android")
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
