import express from 'express'
import { v4 as uuidv4 } from 'uuid';


const headers = {
    AccessControllAllowHeader: 'access-control-allow-origin',
    AccessControllAllowOrigin: 'access-control-allow-origin',
    AccessControllAllowMethods: 'access-control-allow-methods',
    XRequestId: 'x-request-id',
}
export default headers

/**
 * 
 * @param {express.Request} req 
 * @param {express.Response} res 
 * @param {express.NextFunction} next 
 */
export function requestHeadersMiddleware(req, res, next) {
    // https://stackoverflow.com/a/36892077
    req.headers[headers.XRequestId] = uuidv4()
    next();
}

/**
 * 
 * @param {express.Request} req 
 * @param {express.Response} res 
 * @param {express.NextFunction} next 
 */
export function responseHeadersMiddleware(req, res, next) {
    res.setHeader(headers.AccessControllAllowOrigin, '*');
    res.setHeader(headers.AccessControllAllowHeader,'Origin, X-Requested-With, Content-Type, Accept, Authorization');
    res.setHeader(headers.AccessControllAllowMethods, 'GET, POST, PATCH, DELETE');
    next();
}