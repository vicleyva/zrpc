import express from 'express'
const port = 5000;
const app = express()

// const notesRoutes = require('./routes/NotesRoutes.js');
app.use(express.json())

import IndexRoutes from './routes/IndexRoutes.js'
import NotesRoutes from './routes/NotesRoutes.js'
import FilesRoutes from './routes/FilesRoutes.js'

// Global Middleware goes first
// We can use middleware
app.use((req, res, next) => {
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader(
        'Access-Control-Allow-Headers',
        'Origin, X-Requested-With, Content-Type, Accept, Authorization'
    );
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PATCH, DELETE');

    next();
});

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



// Start application on defined port
app.listen(port, () => {
    console.log(`Server is listening at http://localhost:${port}`);
});

