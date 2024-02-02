import express from 'express'
import headers from '../midleware/HeadersMiddleware.js'

/**
 * Get X-Request-ID value
 * @method
 * @param {express.Request} req
 * @returns {Promise<string>}  
 */
export default async function requestId(req) {
    return req.headers[headers.XRequestId.toLowerCase()]
}