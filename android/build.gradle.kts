allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
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

buildscript {
    repositories {
        google() // Добавьте репозиторий здесь
        mavenCentral() // Добавьте репозиторий здесь
    }
    dependencies {
        classpath("com.google.gms:google-services:4.3.15") // проверьте последнюю версию
        classpath("com.android.tools.build:gradle:8.0.0") // Удалите лишнюю кавычку
    }
    
}