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

// Injects concurrent-futures without triggering afterEvaluate lifecycle conflicts
subprojects {
    configurations.all {
        resolutionStrategy.eachDependency {
            if (requested.group == "androidx.concurrent" && requested.name.startsWith("concurrent-futures")) {
                useVersion("1.2.0")
            }
        }
    }
    
    plugins.withId("com.android.library") {
        dependencies.add("compileOnly", "androidx.concurrent:concurrent-futures:1.2.0")
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}