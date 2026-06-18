ThisBuild / scalaVersion := "3.7.4"
ThisBuild / version := "0.1.0"

lazy val root = (project in file("."))
  .settings(
    name := "relocated-pom",
    libraryDependencies += "org.apache.pulsar" % "pulsar-client" % "4.0.5"
  )
