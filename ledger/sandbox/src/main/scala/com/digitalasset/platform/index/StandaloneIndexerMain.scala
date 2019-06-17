// Copyright (c) 2019 Digital Asset (Switzerland) GmbH and/or its affiliates. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package com.digitalasset.platform.index

import java.util.concurrent.atomic.AtomicBoolean

import com.daml.ledger.participant.state.v2.ReadService
import com.digitalasset.platform.common.util.{DirectExecutionContext => DEC}
import com.digitalasset.platform.sandbox.cli.Cli
import org.slf4j.LoggerFactory

import scala.concurrent.Await
import scala.util.control.NonFatal

object StandaloneIndexerMain extends App {
  private val logger = LoggerFactory.getLogger(this.getClass)

  Cli.parse(args).fold(sys.exit(1)) { config =>
    val jdbcUrl = config.jdbcUrl.getOrElse(sys.error("No JDBC URL provided!"))


    val readService: ReadService = null

    val server = PostgresIndexer.create(readService, jdbcUrl)
    val indexHandleF = server.flatMap(_.subscribe(
      readService,
      t => logger.error("error while processing state updates", t),
      () => logger.info("successfully finished processing state updates")))(DEC)

    val indexFeedHandle = Await.result(indexHandleF, PostgresIndexer.asyncTolerance)

    val closed = new AtomicBoolean(false)

    def closeServer(): Unit = {
      if (closed.compareAndSet(false, true)) {
        val _ = Await.result(indexFeedHandle.stop(), PostgresIndexer.asyncTolerance)
      }
    }

    try {
      Runtime.getRuntime.addShutdownHook(new Thread(() => closeServer()))
    } catch {
      case NonFatal(t) => {
        logger.error("Shutting down Sandbox application because of initialization error", t)
        closeServer()
      }
    }
  }

}
