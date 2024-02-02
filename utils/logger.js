import express from 'express'
import SimpleLogger from 'simple-node-logger';
import requestId from './requestId.js';

const logger = SimpleLogger.createRollingFileLogger({
    logDirectory: "./logs",
    fileNamePattern: "<DATE>.log",
    dateFormat: "YYYY.MM.DD"
})

const SEPARATOR = " "

/**
 * 
 * @param {express.Request} req 
 * @param {express.Response} res 
 * @param  {...any} arr 
 * @returns 
 */
const info = async(req, res, ...arr) => logger.info( await requestId(req), SEPARATOR, res.status, SEPARATOR, req.method, SEPARATOR, req.url, ...arr )

/**
 * 
 * @param {express.Request} req 
 * @param  {...any} arr 
 * @returns 
 */
const error = async(req, res, ...arr) => logger.error( await requestId(req),SEPARATOR, res.status, SEPARATOR,req.method, SEPARATOR, req.url,  ...arr )

/**
 * 
 * @param {express.Request} req 
 * @param  {...any} arr 
 * @returns 
 */
const warn =async (req, res, ...arr) => logger.warn( await requestId(req), SEPARATOR, res.status, SEPARATOR,req.method, SEPARATOR, req.url, ...arr )

/**
 * 
 * @param {express.Request} req 
 * @param  {...any} arr 
 * @returns 
 */
const debug = async (req, res, ...arr) => logger.debug( await requestId(req), SEPARATOR, res.status, SEPARATOR,req.method, SEPARATOR, req.url, ...arr )

/**
 * 
 * @param {express.Request} req 
 * @param  {...any} arr 
 * @returns 
 */
const fatal = async (req, res, ...arr) => logger.fatal( await requestId(req), SEPARATOR, res.status, SEPARATOR,req.method, SEPARATOR, req.url, ...arr )

export default { info, error, warn, debug, fatal }