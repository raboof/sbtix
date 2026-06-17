package se.nullable.sbtix

import java.io.File
import java.util.concurrent.ConcurrentSkipListSet

import scala.collection.JavaConverters._

import sbt.{Classpaths, Configuration, Credentials, Resolver}
import sbt.Keys.Classpath
import sbt.librarymanagement.UpdateReport

private[sbtix] object SbtCompat {
  type ResolverAuthentication = lmcoursier.internal.shaded.coursier.core.Authentication

  final case class DirectCredential(userName: String, passwd: String, realm: String)

  def uncached[A](body: => A): A = body

  def ivyLocalResolver(name: String, baseDirectory: File): Resolver =
    Resolver.file(name, baseDirectory)(Resolver.ivyStylePatterns)

  def concurrentSetToSet[A](set: ConcurrentSkipListSet[A]): Set[A] =
    set.asScala.toSet

  def managedJars(
      config: Configuration,
      jarTypes: Set[String],
      report: UpdateReport
  )(implicit converter: xsbti.FileConverter): Classpath =
    Classpaths.managedJars(config, jarTypes, report)

  def credentialForHost(credentials: Seq[Credentials], host: String): Option[DirectCredential] =
    Credentials
      .forHost(credentials, host)
      .map(c => DirectCredential(c.userName, c.passwd, c.realm))

  def resolverAuthentication(
      user: String,
      password: String,
      optional: Boolean,
      realmOpt: Option[String],
      httpsOnly: Boolean,
      passOnRedirect: Boolean
  ): ResolverAuthentication =
    lmcoursier.internal.shaded.coursier.core.Authentication(
      user,
      password,
      optional,
      realmOpt,
      httpsOnly,
      passOnRedirect
    )
}
