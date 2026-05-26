buildscript {
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        // Explicitly put AGP in the classpath so Chaquopy can find it
        // (Flutter delivers AGP via includeBuild which Chaquopy can't see)
        classpath("com.android.tools.build:gradle:8.11.1")
        classpath("com.chaquo.python:gradle:16.0.0")
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

