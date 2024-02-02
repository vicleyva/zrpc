import express from 'express'
import logger from './utils/logger.js'
import { requestHeadersMiddleware, responseHeadersMiddleware } from './midleware/HeadersMiddleware.js'

const port = 5000;
const app = express()

// const notesRoutes = require('./routes/NotesRoutes.js');
app.use(express.json())

import IndexRoutes from './routes/IndexRoutes.js'
import NotesRoutes from './routes/NotesRoutes.js'
import FilesRoutes from './routes/FilesRoutes.js'

// Global Middleware goes first
// We can use middleware
app.use(requestHeadersMiddleware);
app.use(responseHeadersMiddleware);

// This will call Index Route using express router
// No need to define prefix with app.use
app.use(IndexRoutes)


// This will call Notes Routes
// GET    /notes/
// POST   /notes/
// PUT    /notes/
// DELETE /notes/
// We need to register prefix with app.use
app.use('/notes', NotesRoutes)
app.use('/files', FilesRoutes)

// Handle 404
app.use(async (req, res, next) => {
    await logger.warn(req, '404 not found! ')
    res.status(404).json({ msg: ""})
})

// Handle Errors
app.use(async (err, req, res, next) => {
    // Show stack trace in console only in development (default)
    const nodeEnv = process.env.NODE_ENV || "development"
    if(nodeEnv === "development") {
        console.error(err.stack)
    }
    // Is good practice to log these errors to a file
    const e = err.stack.split("\n")
    await logger.error(req, e.join(''))
    res.status(500).send('Something broke!')
})



// Start application on defined port
app.listen(port, () => {
    console.log(`[application] Server is listening at http://localhost:${port}`);
});

